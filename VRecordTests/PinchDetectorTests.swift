import CoreGraphics
import XCTest
@testable import VRecord

final class PinchDetectorTests: XCTestCase {
    func testPinchStartsAfterDebouncedNormalizedDistance() {
        var detector = makeDetector()

        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.16),
            referenceScale: 1
        ))
        XCTAssertTrue(detector.update(
            thumbTip: point(0),
            indexTip: point(0.16),
            referenceScale: 1
        ))
    }

    func testPinchEndsOnlyAfterEndThresholdAndDebounce() {
        var detector = makeDetector()
        beginPinch(&detector)

        XCTAssertTrue(detector.update(
            thumbTip: point(0),
            indexTip: point(0.42),
            referenceScale: 1
        ))
        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.42),
            referenceScale: 1
        ))
    }

    func testHysteresisKeepsActivePinchBetweenThresholds() {
        var detector = makeDetector()
        beginPinch(&detector)

        XCTAssertTrue(detector.update(
            thumbTip: point(0),
            indexTip: point(0.27),
            referenceScale: 1
        ))
        XCTAssertTrue(detector.update(
            thumbTip: point(0),
            indexTip: point(0.27),
            referenceScale: 1
        ))
    }

    func testJitterAroundStartThresholdDoesNotTriggerPinch() {
        var detector = makeDetector()

        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.21),
            referenceScale: 1
        ))
        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.25),
            referenceScale: 1
        ))
        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.21),
            referenceScale: 1
        ))
        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.25),
            referenceScale: 1
        ))
    }

    private func makeDetector() -> PinchDetector {
        PinchDetector(
            configuration: .init(
                startThreshold: 0.23,
                endThreshold: 0.31,
                smoothingFactor: 1,
                debounceFrameCount: 2,
                minimumReferenceScale: 0.001
            )
        )
    }

    private func beginPinch(_ detector: inout PinchDetector) {
        XCTAssertFalse(detector.update(
            thumbTip: point(0),
            indexTip: point(0.16),
            referenceScale: 1
        ))
        XCTAssertTrue(detector.update(
            thumbTip: point(0),
            indexTip: point(0.16),
            referenceScale: 1
        ))
    }

    private func point(_ x: CGFloat) -> NormalizedPoint {
        NormalizedPoint(x: x, y: 0)
    }
}
