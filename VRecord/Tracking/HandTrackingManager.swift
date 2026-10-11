import Foundation
import CoreGraphics
import CoreVideo
import Vision
import ImageIO

/// Capture and rendering never wait for Vision. At most one image is in
/// inference and one pending image is retained; newer submissions replace it.
final class HandTrackingManager {
    private struct Job {
        let buffer: CVPixelBuffer
        let timestamp: TimeInterval
        let generation: UInt64
    }

    private struct Detection {
        let points: [HandJoint: CGPoint]
        let chirality: VNChirality
        let palm: CGPoint
    }

    private struct Identity {
        let id: HandID
        var palm: CGPoint
        var chirality: VNChirality
        var points: [HandJoint: CGPoint]
        var lastSeen: TimeInterval
    }

    private let lock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.vrecord.hand-tracking", qos: .userInitiated)
    private var pending: Job?
    private var running = false
    private var generation: UInt64 = 0
    private var latest = HandTrackingSnapshot(hands: [], timestamp: 0)
    private var lastSubmission = -TimeInterval.greatestFiniteMagnitude
    private let maximumSnapshotAge: TimeInterval = 0.18
    private let minimumInferenceInterval: TimeInterval = 1.0 / 30.0

    // The following are exclusively owned by inferenceQueue.
    private let request: VNDetectHumanHandPoseRequest
    private var sequence = VNSequenceRequestHandler()
    private var workerGeneration = UInt64.max
    private var identities: [Identity] = []
    private var nextID: HandID = 0
    private var pinchDetector = PinchDetector()

    init() {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        // Leave compute-device selection to Vision; no assumed Neural Engine.
    }

    /// timestamp must be monotonic, normally ProcessInfo.processInfo.systemUptime.
    /// Buffer pixels must already be physically rotated to landscape, unmirrored.
    func submit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        lock.lock()
        guard timestamp >= lastSubmission + minimumInferenceInterval else {
            lock.unlock()
            return
        }
        lastSubmission = timestamp
        pending = Job(buffer: pixelBuffer, timestamp: timestamp, generation: generation)
        let shouldStart = !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart {
            inferenceQueue.async { [weak self] in self?.drain() }
        }
    }

    func snapshot(at timestamp: TimeInterval) -> HandTrackingSnapshot {
        lock.lock()
        let result = latest
        lock.unlock()
        let age = timestamp - result.timestamp
        guard age >= -0.02, age <= maximumSnapshotAge else {
            return HandTrackingSnapshot(hands: [], timestamp: timestamp)
        }
        return result
    }

    /// Invalidates an in-flight result immediately without blocking capture.
    func reset() {
        lock.lock()
        generation &+= 1
        pending = nil
        latest = HandTrackingSnapshot(hands: [], timestamp: ProcessInfo.processInfo.systemUptime)
        lastSubmission = -TimeInterval.greatestFiniteMagnitude
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            let result: HandTrackingSnapshot = autoreleasepool {
                if workerGeneration != job.generation {
                    identities.removeAll(keepingCapacity: true)
                    pinchDetector.reset()
                    sequence = VNSequenceRequestHandler()
                    workerGeneration = job.generation
                }
                return process(job)
            }
            lock.lock()
            if job.generation == generation, result.timestamp >= latest.timestamp {
                latest = result
            }
            lock.unlock()
        }
    }

    private func process(_ job: Job) -> HandTrackingSnapshot {
        do {
            try sequence.perform([request], on: job.buffer, orientation: .up)
            let detections = (request.results ?? []).compactMap { observation -> Detection? in
                guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
                var points: [HandJoint: CGPoint] = [:]
                points.reserveCapacity(21)
                for (joint, visionJoint) in Self.visionJoints {
                    guard let point = recognized[visionJoint], point.confidence >= 0.35,
                          point.location.x.isFinite, point.location.y.isFinite else { continue }
                    points[joint] = CGPoint(x: min(1, max(0, point.location.x)),
                                            y: min(1, max(0, 1 - point.location.y)))
                }
                guard points.count >= 5,
                      let palm = points[.middleMCP] ?? points[.wrist] else { return nil }
                return Detection(points: points, chirality: observation.chirality, palm: palm)
            }
            let aspect = CGFloat(CVPixelBufferGetWidth(job.buffer)) / CGFloat(CVPixelBufferGetHeight(job.buffer))
            let hands = associate(detections, timestamp: job.timestamp, aspectRatio: aspect)
            return HandTrackingSnapshot(hands: hands, timestamp: job.timestamp)
        } catch {
            // Fail closed: a Vision failure is tracking loss, never a release.
            pinchDetector.reset()
            return HandTrackingSnapshot(hands: [], timestamp: job.timestamp)
        }
    }

    private func associate(_ detections: [Detection], timestamp: TimeInterval,
                           aspectRatio: CGFloat) -> [HandLandmarks] {
        // Retain identity briefly through occlusion, but never display old bones.
        identities.removeAll { timestamp - $0.lastSeen > 1.0 }
        var used = Set<HandID>()
        var output: [HandLandmarks] = []
        output.reserveCapacity(2)
        for detection in detections.prefix(2) {
            let match = identities.indices.filter { !used.contains(identities[$0].id) }
                .min { cost(identities[$0], detection) < cost(identities[$1], detection) }
            let matchedIndex = match.flatMap { index -> Int? in
                cost(identities[index], detection) < 0.65 ? index : nil
            }
            let id: HandID
            let smoothed: [HandJoint: CGPoint]
            if let index = matchedIndex {
                let old = identities[index]
                id = old.id
                smoothed = smooth(detection.points, previous: old.points,
                                  elapsed: timestamp - old.lastSeen, aspectRatio: aspectRatio)
                identities[index] = Identity(id: id, palm: detection.palm,
                    chirality: detection.chirality, points: smoothed, lastSeen: timestamp)
            } else {
                id = nextID
                nextID += 1
                smoothed = detection.points
                identities.append(Identity(id: id, palm: detection.palm,
                    chirality: detection.chirality, points: smoothed, lastSeen: timestamp))
            }
            used.insert(id)
            // Classify raw, confident points; smoothing the display must not
            // introduce an additional gesture delay or change its geometry.
            let pinch = pinchDetector.update(id: id, points: detection.points,
                at: timestamp, aspectRatio: aspectRatio)
            let handedness: Handedness
            switch detection.chirality {
            case .left: handedness = .left
            case .right: handedness = .right
            default: handedness = .unknown
            }
            output.append(HandLandmarks(id: id, points: smoothed, pinching: pinch.pinching,
                isGestureReliable: pinch.reliable, handedness: handedness))
        }
        pinchDetector.retain(ids: used)
        // Bounded even if ambiguous detections keep generating fresh IDs.
        identities = Array(identities.sorted { $0.lastSeen > $1.lastSeen }.prefix(4))
        return output.sorted { $0.id < $1.id }
    }

    private func cost(_ identity: Identity, _ detection: Detection) -> CGFloat {
        let distance = hypot(identity.palm.x - detection.palm.x,
                             identity.palm.y - detection.palm.y)
        if identity.chirality != .unknown, detection.chirality != .unknown {
            // Prefer anatomical identity when hands cross or return elsewhere.
            return identity.chirality == detection.chirality ? distance * 0.25 : distance + 0.9
        }
        return distance
    }

    private func smooth(_ points: [HandJoint: CGPoint], previous: [HandJoint: CGPoint],
                        elapsed: TimeInterval, aspectRatio: CGFloat) -> [HandJoint: CGPoint] {
        guard elapsed > 0, elapsed < 0.15 else { return points }
        let baseAlpha = CGFloat(1 - exp(-elapsed / 0.025))
        var result = points
        for (joint, point) in points {
            guard let old = previous[joint] else { continue }
            let movement = hypot((point.x - old.x) * aspectRatio, point.y - old.y)
            // Large movements bypass smoothing to avoid visible trailing bones.
            let alpha = movement > 0.035 ? CGFloat(1) : max(0.55, baseAlpha)
            result[joint] = CGPoint(x: old.x + alpha * (point.x - old.x),
                                    y: old.y + alpha * (point.y - old.y))
        }
        return result
    }

    private static let visionJoints: [(HandJoint, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist), (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP),
        (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
    ]
}
