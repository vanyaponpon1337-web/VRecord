import Foundation

enum CaptureState: Equatable {
    case idle
    case pinching(startTime: TimeInterval)
    case recording
}

enum CaptureAction: Equatable {
    case none
    case capturePhoto
    case startRecording
    case stopRecording
}

struct CaptureStateMachine {
    let longPressDuration: TimeInterval
    private(set) var state: CaptureState = .idle

    init(longPressDuration: TimeInterval = 1.0) {
        self.longPressDuration = longPressDuration
    }

    mutating func update(pinchIsActive: Bool, at timestamp: TimeInterval) -> CaptureAction {
        switch state {
        case .idle:
            guard pinchIsActive else {
                return .none
            }

            state = .pinching(startTime: timestamp)
            return .none

        case let .pinching(startTime):
            if pinchIsActive {
                return advance(at: timestamp)
            }

            state = .idle
            return timestamp - startTime <= longPressDuration ? .capturePhoto : .none

        case .recording:
            guard !pinchIsActive else {
                return .none
            }

            state = .idle
            return .stopRecording
        }
    }

    mutating func advance(at timestamp: TimeInterval) -> CaptureAction {
        guard case let .pinching(startTime) = state else {
            return .none
        }

        guard timestamp - startTime > longPressDuration else {
            return .none
        }

        state = .recording
        return .startRecording
    }

    mutating func cancel() -> CaptureAction {
        defer {
            state = .idle
        }

        switch state {
        case .recording:
            return .stopRecording
        case .idle, .pinching:
            return .none
        }
    }
}
