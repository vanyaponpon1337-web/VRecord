import AVFoundation
import ImageIO
import QuartzCore
import Vision

final class HandTrackingManager {
    struct Configuration {
        let maximumAnalysisFPS: Double
        let missingFrameTolerance: Int
        let continuityDistanceThreshold: CGFloat

        init(
            maximumAnalysisFPS: Double = 20,
            missingFrameTolerance: Int = 3,
            continuityDistanceThreshold: CGFloat = 0.22
        ) {
            self.maximumAnalysisFPS = maximumAnalysisFPS
            self.missingFrameTolerance = missingFrameTolerance
            self.continuityDistanceThreshold = continuityDistanceThreshold
        }
    }

    var onHandUpdate: ((HandSkeleton?) -> Void)?

    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let orientation: CGImagePropertyOrientation
        let sourceAspectRatio: CGFloat
    }

    private let configuration: Configuration
    private let visionQueue = DispatchQueue(
        label: "com.example.VRecord.vision",
        qos: .userInitiated
    )
    private let frameLock = NSLock()
    private let handPoseRequest: VNDetectHumanHandPoseRequest

    private var latestFrame: PendingFrame?
    private var isProcessing = false
    private var lastSubmittedTime: CFTimeInterval = 0
    private var previousWrist: NormalizedPoint?
    private var missingFrameCount = 0
    private var pinchDetector = PinchDetector()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration

        let request = VNDetectHumanHandPoseRequest()
        // Vision returns candidates ordered by size. We select and publish exactly one hand.
        request.maximumHandCount = 1
        self.handPoseRequest = request
    }

    func enqueue(
        sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation,
        sourceAspectRatio: CGFloat
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let now = CACurrentMediaTime()
        frameLock.lock()

        guard now - lastSubmittedTime >= 1 / configuration.maximumAnalysisFPS else {
            frameLock.unlock()
            return
        }

        lastSubmittedTime = now
        latestFrame = PendingFrame(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            sourceAspectRatio: sourceAspectRatio
        )

        guard !isProcessing, let frame = latestFrame else {
            frameLock.unlock()
            return
        }

        isProcessing = true
        latestFrame = nil
        frameLock.unlock()

        visionQueue.async { [weak self] in
            self?.process(frame)
        }
    }

    func reset() {
        visionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.previousWrist = nil
            self.missingFrameCount = 0
            self.pinchDetector.reset()
            self.publish(nil)
        }
    }

    private func process(_ frame: PendingFrame) {
        defer {
            processLatestFrameIfNeeded()
        }

        autoreleasepool {
            let requestHandler = VNImageRequestHandler(
                cvPixelBuffer: frame.pixelBuffer,
                orientation: frame.orientation,
                options: [:]
            )

            do {
                try requestHandler.perform([handPoseRequest])
                let observations = handPoseRequest.results ?? []
                handle(observations, sourceAspectRatio: frame.sourceAspectRatio)
            } catch {
                handleNoHand()
            }
        }
    }

    private func handle(
        _ observations: [VNHumanHandPoseObservation],
        sourceAspectRatio: CGFloat
    ) {
        let candidates = observations.compactMap {
            HandSkeleton.make(from: $0)
        }

        guard let selectedHand = selectStableHand(from: candidates) else {
            handleNoHand()
            return
        }

        missingFrameCount = 0
        previousWrist = selectedHand.point(.wrist)
        let isPinching = pinchDetector.update(
            with: selectedHand,
            sourceAspectRatio: sourceAspectRatio
        )
        publish(selectedHand.updatingPinchState(isPinching))
    }

    private func selectStableHand(from candidates: [HandSkeleton]) -> HandSkeleton? {
        guard !candidates.isEmpty else {
            return nil
        }

        guard let previousWrist else {
            return candidates.max { $0.confidence < $1.confidence }
        }

        let nearest = candidates.min { lhs, rhs in
            guard let leftWrist = lhs.point(.wrist), let rightWrist = rhs.point(.wrist) else {
                return lhs.confidence < rhs.confidence
            }

            return leftWrist.distance(to: previousWrist) < rightWrist.distance(to: previousWrist)
        }

        if
            let nearest,
            let nearestWrist = nearest.point(.wrist),
            nearestWrist.distance(to: previousWrist) <= configuration.continuityDistanceThreshold
        {
            return nearest
        }

        return candidates.max { $0.confidence < $1.confidence }
    }

    private func handleNoHand() {
        missingFrameCount += 1

        guard missingFrameCount > configuration.missingFrameTolerance else {
            return
        }

        previousWrist = nil
        pinchDetector.reset()
        publish(nil)
    }

    private func publish(_ hand: HandSkeleton?) {
        onHandUpdate?(hand)
    }

    private func processLatestFrameIfNeeded() {
        frameLock.lock()

        guard let nextFrame = latestFrame else {
            isProcessing = false
            frameLock.unlock()
            return
        }

        latestFrame = nil
        frameLock.unlock()

        visionQueue.async { [weak self] in
            self?.process(nextFrame)
        }
    }
}
