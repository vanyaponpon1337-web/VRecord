import Foundation
import CoreGraphics

/// Time-based filtering and hysteresis, independently maintained for each ID.
/// Distances are corrected for the source aspect ratio before normalization.
struct PinchDetector {
    struct Configuration {
        var startRatio: CGFloat = 0.30
        var releaseRatio: CGFloat = 0.46
        var startStability: TimeInterval = 0.045
        var releaseStability: TimeInterval = 0.055
        var filterTimeConstant: TimeInterval = 0.035
        var maximumObservationGap: TimeInterval = 0.25
    }

    struct Measurement {
        let pinching: Bool
        let reliable: Bool
    }

    private struct Track {
        var pinching = false
        var hasStableState = false
        var filteredRatio: CGFloat?
        var candidateSince: TimeInterval?
        var lastTime: TimeInterval?
    }

    private var tracks: [HandID: Track] = [:]
    let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func update(id: HandID, points: [HandJoint: CGPoint],
                         at timestamp: TimeInterval, aspectRatio: CGFloat = 1) -> Measurement {
        guard timestamp.isFinite, aspectRatio.isFinite, aspectRatio > 0,
              let thumb = points[.thumbTip], let index = points[.indexTip],
              let wrist = points[.wrist], let middle = points[.middleMCP],
              let indexBase = points[.indexMCP], let littleBase = points[.littleMCP]
        else {
            tracks.removeValue(forKey: id)
            return Measurement(pinching: false, reliable: false)
        }
        let palm = max(distance(wrist, middle, aspectRatio),
                       distance(indexBase, littleBase, aspectRatio))
        guard palm > 0.012 else {
            tracks.removeValue(forKey: id)
            return Measurement(pinching: false, reliable: false)
        }
        let ratio = distance(thumb, index, aspectRatio) / palm
        guard ratio.isFinite else {
            tracks.removeValue(forKey: id)
            return Measurement(pinching: false, reliable: false)
        }
        var track = tracks[id] ?? Track()
        if let previous = track.lastTime {
            // An out-of-order sample cannot change an established gesture.
            guard timestamp >= previous else {
                return Measurement(pinching: track.pinching, reliable: track.hasStableState)
            }
            if timestamp - previous > configuration.maximumObservationGap {
                track = Track()
            }
        }
        let elapsed = track.lastTime.map { max(0, timestamp - $0) }
        if let previousRatio = track.filteredRatio, let elapsed {
            let alpha = CGFloat(1 - exp(-elapsed / max(0.001, configuration.filterTimeConstant)))
            track.filteredRatio = previousRatio + alpha * (ratio - previousRatio)
        } else {
            track.filteredRatio = ratio
        }
        let filtered = track.filteredRatio ?? ratio
        // After an occlusion, a closed hand is unclassified until its onset
        // debounce completes. Reporting a reliable "released" state in this
        // interval could arm recording stop for the original held pinch.
        if !track.hasStableState, filtered >= configuration.releaseRatio {
            track.hasStableState = true
        }
        let wantsTransition = track.pinching
            ? filtered >= configuration.releaseRatio
            : filtered <= configuration.startRatio
        if wantsTransition {
            if track.candidateSince == nil { track.candidateSince = timestamp }
            let stability = track.pinching
                ? configuration.releaseStability : configuration.startStability
            if timestamp - (track.candidateSince ?? timestamp) >= stability {
                track.pinching.toggle()
                track.hasStableState = true
                track.candidateSince = nil
            }
        } else {
            track.candidateSince = nil
        }
        track.lastTime = timestamp
        tracks[id] = track
        return Measurement(pinching: track.pinching, reliable: track.hasStableState)
    }

    mutating func retain(ids: Set<HandID>) {
        tracks = tracks.filter { ids.contains($0.key) }
    }

    mutating func reset() { tracks.removeAll(keepingCapacity: true) }

    private func distance(_ a: CGPoint, _ b: CGPoint, _ aspect: CGFloat) -> CGFloat {
        hypot((a.x - b.x) * aspect, a.y - b.y)
    }
}
