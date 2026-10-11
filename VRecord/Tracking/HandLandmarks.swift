import Foundation
import CoreGraphics

typealias HandID = Int

enum Handedness: Hashable {
    case left, right, unknown
}

/// Coordinates are normalized in the unmirrored, landscape camera buffer, with
/// the origin at its top-left. Preview cropping is deliberately applied later.
enum HandJoint: CaseIterable, Hashable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

struct HandLandmarks {
    let id: HandID
    var points: [HandJoint: CGPoint]
    var pinching: Bool
    /// False when the fingertips/palm needed for a safe gesture are occluded.
    /// A missing measurement must never masquerade as a deliberate release.
    var isGestureReliable: Bool
    /// Vision's anatomical handedness helps re-identify an initiating hand
    /// after a longer occlusion has necessarily replaced its spatial track.
    var handedness: Handedness

    init(id: HandID, points: [HandJoint: CGPoint], pinching: Bool,
         isGestureReliable: Bool = true, handedness: Handedness = .unknown) {
        self.id = id
        self.points = points
        self.pinching = pinching
        self.isGestureReliable = isGestureReliable
        self.handedness = handedness
    }

    static let bones: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP),
        (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP),
        (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP),
        (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP),
        (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP),
        (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP),
        (.ringMCP, .littleMCP)
    ]
}

struct HandTrackingSnapshot {
    let hands: [HandLandmarks]
    /// Monotonic capture time, in the same ProcessInfo.systemUptime domain
    /// supplied to HandTrackingManager.submit and snapshot.
    let timestamp: TimeInterval
}
