import Foundation

enum GestureAction: Equatable {
    case takePhoto
    case startRecording
    case stopRecording
}

/// Owned exclusively by the camera pipeline's serial queue. All times use the
/// monotonic capture clock, never Date or a count of delivered frames.
struct GestureStateMachine {
    enum State: Equatable { case idle, pinchPending, recording, finalizing }

    private struct HandState {
        var pinching = false
        var startedAt: TimeInterval?
        var consumed = false
        var lost = false
        var handedness: Handedness = .unknown
    }

    private(set) var state: State = .idle
    private var tracks: [HandID: HandState] = [:]
    private var initiatingHand: HandID?
    private var initiatingHandedness: Handedness = .unknown
    private var stopArmed = false
    private var requiresRelease = false
    private var releaseBarrierSides = Set<Handedness>()
    private var lastTimestamp: TimeInterval?
    let longPinchDuration: TimeInterval

    var isRecording: Bool { state == .recording }

    init(longPinchDuration: TimeInterval = 1) {
        self.longPinchDuration = longPinchDuration
    }

    mutating func update(hands: [HandLandmarks], at timestamp: TimeInterval) -> [GestureAction] {
        guard timestamp.isFinite else { return [] }
        if let previous = lastTimestamp, timestamp < previous { return [] }
        lastTimestamp = timestamp

        // Duplicate IDs cannot race or cause Dictionary(uniqueKeys...) crashes.
        var reliable: [HandID: HandLandmarks] = [:]
        for hand in hands where hand.isGestureReliable { reliable[hand.id] = hand }
        let armedAtStart = stopArmed
        if state == .recording, !stopArmed, reliable[initiatingHand ?? -1] == nil,
           initiatingHandedness != .unknown,
           let reacquired = reliable.values.first(where: { $0.handedness == initiatingHandedness }) {
            // A long occlusion may replace the spatial ID. Only the same
            // anatomical hand can fulfill the initiating-release requirement.
            initiatingHand = reacquired.id
            if !reacquired.pinching { stopArmed = true }
        }
        var onsets: [HandID] = []
        var photoCandidates: [HandID] = []

        for id in Array(tracks.keys) where reliable[id] == nil {
            var track = tracks[id] ?? HandState()
            // Tracking loss cancels a pending gesture. A held pinch reacquired
            // with this ID must first visibly release before another command.
            track.startedAt = nil
            track.consumed = true
            track.lost = true
            tracks[id] = track
        }

        for id in reliable.keys.sorted() {
            guard let hand = reliable[id] else { continue }
            var track = tracks[id] ?? HandState()
            if hand.handedness != .unknown { track.handedness = hand.handedness }
            if track.lost {
                track.lost = false
                if hand.pinching {
                    track.pinching = true
                    track.consumed = true
                    track.startedAt = nil
                }
            }
            if hand.pinching && !track.pinching {
                track.pinching = true
                track.startedAt = timestamp
                track.consumed = state == .finalizing
                if !track.consumed { onsets.append(id) }
            } else if !hand.pinching && track.pinching {
                if (state == .idle || state == .pinchPending), !track.consumed,
                   let start = track.startedAt, timestamp - start < longPinchDuration {
                    photoCandidates.append(id)
                }
                if state == .recording, initiatingHand == id { stopArmed = true }
                track.pinching = false
                track.startedAt = nil
                track.consumed = false
            }
            tracks[id] = track
        }

        if requiresRelease {
            consumeHeldPinches()
            for hand in reliable.values where !hand.pinching {
                releaseBarrierSides.remove(hand.handedness)
            }
            // Empty or unreliable observations are tracking loss, not proof of
            // release. Known consumed sides must each be observed open, even
            // if a reset has replaced their spatial IDs.
            if releaseBarrierSides.isEmpty, !reliable.isEmpty,
               reliable.values.allSatisfy({ !$0.pinching }) {
                requiresRelease = false
            }
            if state == .pinchPending { state = .idle }
            pruneLostTracks()
            return []
        }

        if state == .finalizing {
            if reliable.values.contains(where: { $0.pinching }) { armReleaseBarrier() }
            consumeHeldPinches()
            pruneLostTracks()
            return []
        }

        if state == .recording {
            // A release and other-hand onset in the same inference cannot race:
            // the stop gate must have been armed before this observation.
            if armedAtStart && !onsets.isEmpty {
                state = .finalizing
                armReleaseBarrier()
                consumeHeldPinches()
                pruneLostTracks()
                return [.stopRecording]
            }
            consumeHeldPinches()
            pruneLostTracks()
            return []
        }

        // Starting a video wins over a simultaneous short release by the other
        // hand, so one observation produces a single global media command.
        let held = tracks.filter { !$0.value.lost && $0.value.pinching && !$0.value.consumed }
        let starter = held.filter { item in
            item.value.startedAt.map { timestamp - $0 >= longPinchDuration } ?? false
        }.sorted { a, b in
            let first = a.value.startedAt ?? timestamp
            let second = b.value.startedAt ?? timestamp
            return first == second ? a.key < b.key : first < second
        }.first
        if let starter {
            state = .recording
            initiatingHand = starter.key
            initiatingHandedness = starter.value.handedness
            stopArmed = false
            consumeHeldPinches()
            pruneLostTracks()
            return [.startRecording]
        }

        state = held.isEmpty ? .idle : .pinchPending
        pruneLostTracks()
        // Each physical short gesture emits exactly one event. A genuinely
        // simultaneous two-hand short pinch is treated as one shutter command.
        return photoCandidates.isEmpty ? [] : [.takePhoto]
    }

    /// Call after AVAssetWriter finalization (including a failed start). Held
    /// stop gestures remain consumed, so they cannot restart recording.
    mutating func finishFinalizing() {
        // A failed recording start may call this directly. For a normal stop,
        // preserve releases already observed while the writer was finalizing.
        if state != .finalizing { armReleaseBarrier() }
        state = .idle
        initiatingHand = nil
        initiatingHandedness = .unknown
        stopArmed = false
        consumeHeldPinches()
    }

    /// Cancels photos in progress, for interruption/orientation/memory changes.
    mutating func cancelPending() {
        consumeHeldPinches()
        if state == .pinchPending { state = .idle }
    }

    /// Used by camera/audio interruption and backgrounding.
    mutating func interrupt() -> [GestureAction] {
        cancelPending()
        if state == .finalizing { return [] }
        armReleaseBarrier()
        guard state == .recording else { return [] }
        state = .finalizing
        return [.stopRecording]
    }

    private mutating func consumeHeldPinches() {
        for id in Array(tracks.keys) {
            guard var track = tracks[id] else { continue }
            if track.pinching { track.consumed = true }
            track.startedAt = nil
            tracks[id] = track
        }
    }

    private mutating func armReleaseBarrier() {
        requiresRelease = true
        for track in tracks.values where track.pinching && !track.lost && track.handedness != .unknown {
            releaseBarrierSides.insert(track.handedness)
        }
    }

    private mutating func pruneLostTracks() {
        // Hand IDs are bounded in normal tracking. Preserve the initiating ID
        // and consumed held IDs, but do not grow without bound after long loss.
        if tracks.count > 16 {
            let keep = Set(tracks.filter { !$0.value.lost }.map(\.key))
            tracks = tracks.filter { keep.contains($0.key) || $0.key == initiatingHand }
        }
    }
}
