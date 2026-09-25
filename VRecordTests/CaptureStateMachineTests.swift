import XCTest
@testable import VRecord

final class CaptureStateMachineTests: XCTestCase {
    func testIdleTransitionsToPinching() {
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.update(pinchIsActive: true, at: 0), .none)
        XCTAssertEqual(machine.state, .pinching(startTime: 0))
    }

    func testShortPinchAtPointTwoSecondsTakesPhotoAfterRelease() {
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.update(pinchIsActive: true, at: 10), .none)
        XCTAssertEqual(machine.update(pinchIsActive: false, at: 10.2), .capturePhoto)
        XCTAssertEqual(machine.state, .idle)
    }

    func testShortPinchAtPointEightSecondsTakesPhotoAfterRelease() {
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.update(pinchIsActive: true, at: 10), .none)
        XCTAssertEqual(machine.update(pinchIsActive: false, at: 10.8), .capturePhoto)
        XCTAssertEqual(machine.state, .idle)
    }

    func testExactlyOneSecondStillTakesPhoto() {
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.update(pinchIsActive: true, at: 10), .none)
        XCTAssertEqual(machine.advance(at: 11), .none)
        XCTAssertEqual(machine.update(pinchIsActive: false, at: 11), .capturePhoto)
        XCTAssertEqual(machine.state, .idle)
    }

    func testLongPinchStartsVideoThenStopsOnRelease() {
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.update(pinchIsActive: true, at: 10), .none)
        XCTAssertEqual(machine.advance(at: 11.01), .startRecording)
        XCTAssertEqual(machine.state, .recording)
        XCTAssertEqual(machine.update(pinchIsActive: false, at: 11.2), .stopRecording)
        XCTAssertEqual(machine.state, .idle)
    }

    func testActiveUpdateAfterOnePointZeroOneSecondsStartsVideo() {
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.update(pinchIsActive: true, at: 10), .none)
        XCTAssertEqual(machine.update(pinchIsActive: true, at: 11.01), .startRecording)
        XCTAssertEqual(machine.state, .recording)
    }
}
