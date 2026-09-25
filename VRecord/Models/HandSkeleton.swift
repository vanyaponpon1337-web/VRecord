import CoreGraphics
import Foundation
import Vision

struct NormalizedPoint: Equatable, Hashable {
    let x: CGFloat
    let y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    func distance(to other: NormalizedPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    func distance(to other: NormalizedPoint, sourceAspectRatio: CGFloat) -> CGFloat {
        hypot((x - other.x) * sourceAspectRatio, y - other.y)
    }
}

enum HandJoint: String, CaseIterable, Hashable {
    case wrist
    case thumbCMC
    case thumbMP
    case thumbIP
    case thumbTip
    case indexMCP
    case indexPIP
    case indexDIP
    case indexTip
    case middleMCP
    case middlePIP
    case middleDIP
    case middleTip
    case ringMCP
    case ringPIP
    case ringDIP
    case ringTip
    case littleMCP
    case littlePIP
    case littleDIP
    case littleTip
}

struct HandSkeleton: Equatable {
    let points: [HandJoint: NormalizedPoint]
    let confidence: Float
    let isPinching: Bool

    init(
        points: [HandJoint: NormalizedPoint],
        confidence: Float,
        isPinching: Bool = false
    ) {
        self.points = points
        self.confidence = confidence
        self.isPinching = isPinching
    }

    func point(_ joint: HandJoint) -> NormalizedPoint? {
        points[joint]
    }

    func updatingPinchState(_ isPinching: Bool) -> HandSkeleton {
        HandSkeleton(points: points, confidence: confidence, isPinching: isPinching)
    }

    static let connections: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC),
        (.thumbCMC, .thumbMP),
        (.thumbMP, .thumbIP),
        (.thumbIP, .thumbTip),

        (.wrist, .indexMCP),
        (.indexMCP, .indexPIP),
        (.indexPIP, .indexDIP),
        (.indexDIP, .indexTip),

        (.wrist, .middleMCP),
        (.middleMCP, .middlePIP),
        (.middlePIP, .middleDIP),
        (.middleDIP, .middleTip),

        (.wrist, .ringMCP),
        (.ringMCP, .ringPIP),
        (.ringPIP, .ringDIP),
        (.ringDIP, .ringTip),

        (.wrist, .littleMCP),
        (.littleMCP, .littlePIP),
        (.littlePIP, .littleDIP),
        (.littleDIP, .littleTip),

        (.indexMCP, .middleMCP),
        (.middleMCP, .ringMCP),
        (.ringMCP, .littleMCP)
    ]
}

extension HandSkeleton {
    static func make(
        from observation: VNHumanHandPoseObservation,
        minimumConfidence: Float = 0.25
    ) -> HandSkeleton? {
        let recognizedPoints: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]

        do {
            recognizedPoints = try observation.recognizedPoints(.all)
        } catch {
            return nil
        }

        let mapping: [(HandJoint, VNHumanHandPoseObservation.JointName)] = [
            (.wrist, .wrist),
            (.thumbCMC, .thumbCMC),
            (.thumbMP, .thumbMP),
            (.thumbIP, .thumbIP),
            (.thumbTip, .thumbTip),
            (.indexMCP, .indexMCP),
            (.indexPIP, .indexPIP),
            (.indexDIP, .indexDIP),
            (.indexTip, .indexTip),
            (.middleMCP, .middleMCP),
            (.middlePIP, .middlePIP),
            (.middleDIP, .middleDIP),
            (.middleTip, .middleTip),
            (.ringMCP, .ringMCP),
            (.ringPIP, .ringPIP),
            (.ringDIP, .ringDIP),
            (.ringTip, .ringTip),
            (.littleMCP, .littleMCP),
            (.littlePIP, .littlePIP),
            (.littleDIP, .littleDIP),
            (.littleTip, .littleTip)
        ]

        var points: [HandJoint: NormalizedPoint] = [:]
        var confidenceTotal: Float = 0

        for (joint, visionJoint) in mapping {
            guard let point = recognizedPoints[visionJoint], point.confidence >= minimumConfidence else {
                continue
            }

            points[joint] = NormalizedPoint(point.location)
            confidenceTotal += point.confidence
        }

        guard points[.wrist] != nil, points.count >= 6 else {
            return nil
        }

        return HandSkeleton(
            points: points,
            confidence: confidenceTotal / Float(points.count)
        )
    }
}
