import XCTest
import CoreGraphics
#if canImport(VRecordCore)
@testable import VRecordCore
#else
@testable import VRecord
#endif

final class GestureStateMachineTests: XCTestCase {
    private func hand(_ id: Int, _ pinching: Bool, reliable: Bool = true,
                      side: Handedness = .unknown) -> HandLandmarks {
        HandLandmarks(id: id, points: [:], pinching: pinching,
                      isGestureReliable: reliable, handedness: side)
    }

    func testLeftShortPinchProducesExactlyOnePhoto() {
        var machine = GestureStateMachine()
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 0), [])
        XCTAssertEqual(machine.state, .pinchPending)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 0.3), [.takePhoto])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 0.4), [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testRightShortPinchProducesExactlyOnePhoto() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(1, true)], at: 0)
        XCTAssertEqual(machine.update(hands: [hand(1, false)], at: 0.7), [.takePhoto])
        XCTAssertEqual(machine.update(hands: [hand(1, false)], at: 0.8), [])
    }

    func testLongPinchEitherHandStartsWithoutRelease() {
        for (id, hold) in [(0, 1.5), (1, 2.0)] {
            var machine = GestureStateMachine()
            _ = machine.update(hands: [hand(id, true)], at: 0)
            XCTAssertEqual(machine.update(hands: [hand(id, true)], at: 0.999), [])
            XCTAssertEqual(machine.update(hands: [hand(id, true)], at: 1), [.startRecording])
            XCTAssertEqual(machine.update(hands: [hand(id, true)], at: hold), [])
            XCTAssertTrue(machine.isRecording)
        }
    }

    func testReleasingInitiatorDoesNotStopRecording() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        _ = machine.update(hands: [hand(0, true)], at: 1)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 1.5), [])
        XCTAssertTrue(machine.isRecording)
    }

    func testNewShortPinchStopsAtOnsetAndProducesNoPhoto() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        _ = machine.update(hands: [hand(0, true)], at: 1)
        _ = machine.update(hands: [hand(0, false)], at: 1.1)
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 1.3), [.stopRecording])
        XCTAssertFalse(machine.isRecording)
        XCTAssertEqual(machine.state, .finalizing)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 1.4), [])
        machine.finishFinalizing()
        XCTAssertEqual(machine.state, .idle)
    }

    func testOtherHandLongStopPinchStopsImmediatelyAndCannotRestartWhenHeld() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 0)
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 1)
        _ = machine.update(hands: [hand(0, false), hand(1, false)], at: 1.2)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 1.3), [.stopRecording])
        machine.finishFinalizing()
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 3.3), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, false)], at: 3.4), [])
        XCTAssertFalse(machine.isRecording)
        _ = machine.update(hands: [hand(1, true)], at: 3.5)
        XCTAssertEqual(machine.update(hands: [hand(1, true)], at: 4.5), [.startRecording])
    }

    func testContinuouslyHeldStartingPinchNeverStops() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        _ = machine.update(hands: [hand(0, true)], at: 1)
        for time in [1.1, 2.0, 10.0, 30.0] {
            XCTAssertEqual(machine.update(hands: [hand(0, true)], at: time), [])
            XCTAssertTrue(machine.isRecording)
        }
    }

    func testSimultaneousOtherHandPinchDoesNotStopInitiation() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true), hand(1, true)], at: 0)
        XCTAssertEqual(machine.update(hands: [hand(0, true), hand(1, true)], at: 1), [.startRecording])
        XCTAssertEqual(machine.update(hands: [hand(0, true), hand(1, true)], at: 2), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 2.1), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 3), [])
        _ = machine.update(hands: [hand(0, false), hand(1, false)], at: 3.1)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 3.2), [.stopRecording])
    }

    func testOtherHandCannotStopUntilInitiatingHandReleases() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 0)
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 1)
        XCTAssertEqual(machine.update(hands: [hand(0, true), hand(1, true)], at: 1.2), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 1.3), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 2.4), [])
        XCTAssertTrue(machine.isRecording)
    }

    func testReleaseAndOtherHandOnsetInSameObservationDoNotRace() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 0)
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 1)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 1.1), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 2.2), [])
        _ = machine.update(hands: [hand(0, false), hand(1, false)], at: 2.3)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 2.4), [.stopRecording])
    }

    func testTrackingLossCancelsShortPhotoAndHeldReacquisition() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        XCTAssertEqual(machine.update(hands: [], at: 0.2), [])
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 0.3), [])
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 2), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 2.1), [])
        _ = machine.update(hands: [hand(0, true)], at: 2.2)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 2.5), [.takePhoto])
    }

    func testOccludedFingertipsDoNotCreatePhoto() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        XCTAssertEqual(machine.update(hands: [hand(0, false, reliable: false)], at: 0.1), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 0.2), [])
    }

    func testLostInitiatorDoesNotArmStopUntilObservedReleased() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 0)
        _ = machine.update(hands: [hand(0, true), hand(1, false)], at: 1)
        _ = machine.update(hands: [hand(1, false)], at: 1.1)
        XCTAssertEqual(machine.update(hands: [hand(1, true)], at: 1.2), [])
        _ = machine.update(hands: [hand(0, false), hand(1, false)], at: 1.3)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 1.4), [.stopRecording])
    }

    func testBothHandsCanBeTrackedAndPinchIndependently() {
        let left = hand(0, true)
        let right = hand(1, false)
        XCTAssertTrue(left.pinching)
        XCTAssertFalse(right.pinching)
        var machine = GestureStateMachine()
        _ = machine.update(hands: [left, right], at: 0)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, true)], at: 0.3), [.takePhoto])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, false)], at: 0.7), [.takePhoto])
    }

    func testSimultaneousShortPinchesEmitOneShutterCommand() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true), hand(1, true)], at: 0)
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, false)], at: 0.3), [.takePhoto])
        XCTAssertEqual(machine.update(hands: [hand(0, false), hand(1, false)], at: 0.4), [])
    }

    func testBackgroundInterruptionStopsAndCancelsPendingCommands() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        XCTAssertEqual(machine.interrupt(), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 0.3), [])
        _ = machine.update(hands: [hand(0, true)], at: 0.4)
        _ = machine.update(hands: [hand(0, true)], at: 1.41)
        XCTAssertEqual(machine.interrupt(), [.stopRecording])
        XCTAssertEqual(machine.interrupt(), [])
        XCTAssertEqual(machine.state, .finalizing)
    }

    func testOutOfOrderTimestampCannotTriggerAnAction() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 1)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 0.5), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 1.3), [.takePhoto])
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: .nan), [])
    }

    func testFailedRecordingStartRequiresFreshGesture() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true)], at: 0)
        _ = machine.update(hands: [hand(0, true)], at: 1)
        machine.finishFinalizing()
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 2), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 2.1), [])
        _ = machine.update(hands: [hand(0, true)], at: 2.2)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 2.4), [.takePhoto])
    }

    func testReleasedInitiatorReidentifiedAfterLongLossArmsStop() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 1)
        _ = machine.update(hands: [], at: 1.2)
        XCTAssertEqual(machine.update(hands: [hand(2, false, side: .left)], at: 3), [])
        XCTAssertEqual(machine.update(hands: [hand(2, false, side: .left), hand(3, true, side: .right)], at: 3.1), [.stopRecording])
    }

    func testOtherReleasedHandCannotImpersonateLostInitiator() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 1)
        _ = machine.update(hands: [], at: 1.2)
        _ = machine.update(hands: [hand(2, false, side: .right)], at: 3)
        XCTAssertEqual(machine.update(hands: [hand(2, true, side: .right)], at: 3.1), [])
        XCTAssertTrue(machine.isRecording)
    }

    func testHeldInitiatorReidentifiedAfterLossMustStillRelease() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 1)
        _ = machine.update(hands: [], at: 1.2)
        XCTAssertEqual(machine.update(hands: [hand(2, true, side: .left)], at: 3), [])
        XCTAssertEqual(machine.update(hands: [hand(2, true, side: .left)], at: 5), [])
        _ = machine.update(hands: [hand(2, false, side: .left)], at: 5.1)
        XCTAssertEqual(machine.update(hands: [hand(2, true, side: .left)], at: 5.2), [.stopRecording])
    }

    func testHeldStopWithNewIdentityCannotRestartAfterFinalization() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 1)
        _ = machine.update(hands: [hand(0, false, side: .left)], at: 1.1)
        XCTAssertEqual(machine.update(hands: [hand(1, true, side: .right)], at: 1.2), [.stopRecording])
        machine.finishFinalizing()
        XCTAssertEqual(machine.update(hands: [], at: 1.3), [])
        XCTAssertEqual(machine.update(hands: [hand(4, true, side: .right)], at: 2), [])
        XCTAssertEqual(machine.update(hands: [hand(4, true, side: .right)], at: 4), [])
        XCTAssertEqual(machine.update(hands: [hand(4, false, side: .right)], at: 4.1), [])
        _ = machine.update(hands: [hand(4, true, side: .right)], at: 4.2)
        XCTAssertEqual(machine.update(hands: [hand(4, false, side: .right)], at: 4.4), [.takePhoto])
    }

    func testOpenOtherHandDoesNotClearLostStopHandsReleaseBarrier() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 1)
        _ = machine.update(hands: [hand(0, false, side: .left)], at: 1.1)
        _ = machine.update(hands: [hand(0, false, side: .left), hand(1, true, side: .right)], at: 1.2)
        machine.finishFinalizing()
        _ = machine.update(hands: [hand(0, false, side: .left)], at: 1.3)
        XCTAssertEqual(machine.update(hands: [hand(4, true, side: .right)], at: 2), [])
        XCTAssertEqual(machine.update(hands: [hand(4, true, side: .right)], at: 4), [])
        XCTAssertFalse(machine.isRecording)
    }

    func testInterruptionConsumesHeldPinchAcrossTrackingReset() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        XCTAssertEqual(machine.interrupt(), [])
        XCTAssertEqual(machine.update(hands: [], at: 0.2), [])
        XCTAssertEqual(machine.update(hands: [hand(5, true, side: .left)], at: 1), [])
        XCTAssertEqual(machine.update(hands: [hand(5, true, side: .left)], at: 3), [])
        XCTAssertEqual(machine.update(hands: [hand(5, false, side: .left)], at: 3.1), [])
        _ = machine.update(hands: [hand(5, true, side: .left)], at: 3.2)
        XCTAssertEqual(machine.update(hands: [hand(5, false, side: .left)], at: 3.4), [.takePhoto])
    }

    func testReleaseDuringFinalizationAllowsFreshGestureAfterCompletion() {
        var machine = GestureStateMachine()
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 0)
        _ = machine.update(hands: [hand(0, true, side: .left)], at: 1)
        _ = machine.update(hands: [hand(0, false, side: .left)], at: 1.1)
        _ = machine.update(hands: [hand(1, true, side: .right)], at: 1.2)
        XCTAssertEqual(machine.update(hands: [hand(1, false, side: .right)], at: 1.3), [])
        machine.finishFinalizing()
        _ = machine.update(hands: [hand(1, true, side: .right)], at: 1.4)
        XCTAssertEqual(machine.update(hands: [hand(1, false, side: .right)], at: 1.6), [.takePhoto])
    }

    func testInterruptionBeforeAnyHandStillRequiresObservedRelease() {
        var machine = GestureStateMachine()
        XCTAssertEqual(machine.interrupt(), [])
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 0), [])
        XCTAssertEqual(machine.update(hands: [hand(0, true)], at: 2), [])
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 2.1), [])
        _ = machine.update(hands: [hand(0, true)], at: 2.2)
        XCTAssertEqual(machine.update(hands: [hand(0, false)], at: 2.4), [.takePhoto])
    }
}
