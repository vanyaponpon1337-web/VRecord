import XCTest
import CoreGraphics
#if canImport(VRecordCore)
@testable import VRecordCore
#else
@testable import VRecord
#endif

final class PinchDetectorTests: XCTestCase {
    /// A palm of size `scale`, with tips separated by ratio * palm size.
    private func points(ratio: CGFloat, scale: CGFloat = 0.2,
                        aspect: CGFloat = 1) -> [HandJoint: CGPoint] {
        [
            .wrist: CGPoint(x: 0.5, y: 0.7),
            .middleMCP: CGPoint(x: 0.5, y: 0.7 - scale),
            .indexMCP: CGPoint(x: 0.5 - scale * 0.4 / aspect, y: 0.7 - scale),
            .littleMCP: CGPoint(x: 0.5 + scale * 0.4 / aspect, y: 0.7 - scale),
            .thumbTip: CGPoint(x: 0.5, y: 0.3),
            .indexTip: CGPoint(x: 0.5 + ratio * scale / aspect, y: 0.3)
        ]
    }

    private func immediateFilterConfiguration() -> PinchDetector.Configuration {
        var config = PinchDetector.Configuration()
        config.filterTimeConstant = 0.001
        return config
    }

    func testPinchRequiresTimeStabilityAndReleasesWithHysteresis() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.2), at: 0).pinching)
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.2), at: 0.02).pinching)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2), at: 0.05).pinching)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.38), at: 0.08).pinching)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.6), at: 0.10).pinching)
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.6), at: 0.17).pinching)
    }

    func testDistancesNormalizeAcrossHandSizesAndLandscapeAspect() {
        for scale: CGFloat in [0.05, 0.1, 0.2, 0.4] {
            for aspect: CGFloat in [1, 16.0 / 9.0, 4.0 / 3.0] {
                var detector = PinchDetector(configuration: immediateFilterConfiguration())
                _ = detector.update(id: 0, points: points(ratio: 0.2, scale: scale, aspect: aspect), at: 0, aspectRatio: aspect)
                XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2, scale: scale, aspect: aspect), at: 0.06, aspectRatio: aspect).pinching)
            }
        }
    }

    func testBothHandsRemainIndependentAndReleaseColorsSeparately() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        _ = detector.update(id: 0, points: points(ratio: 0.2), at: 0)
        _ = detector.update(id: 1, points: points(ratio: 0.8), at: 0)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2), at: 0.06).pinching)
        XCTAssertFalse(detector.update(id: 1, points: points(ratio: 0.8), at: 0.06).pinching)
        _ = detector.update(id: 1, points: points(ratio: 0.2), at: 0.1)
        XCTAssertTrue(detector.update(id: 1, points: points(ratio: 0.2), at: 0.16).pinching)
        _ = detector.update(id: 0, points: points(ratio: 0.8), at: 0.17)
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.8), at: 0.24).pinching)
        XCTAssertTrue(detector.update(id: 1, points: points(ratio: 0.2), at: 0.24).pinching)
    }

    func testJitterAndSingleShortSpikeDoNotTrigger() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        for (time, ratio) in [(0.0, 0.29), (0.02, 0.34), (0.04, 0.28), (0.06, 0.33), (0.08, 0.29), (0.1, 0.6)] {
            XCTAssertFalse(detector.update(id: 0, points: points(ratio: CGFloat(ratio)), at: time).pinching)
        }
    }

    func testMissingTipIsUnreliableAndResetsGesture() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        _ = detector.update(id: 0, points: points(ratio: 0.2), at: 0)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2), at: 0.06).pinching)
        var occluded = points(ratio: 0.2)
        occluded.removeValue(forKey: .thumbTip)
        let measurement = detector.update(id: 0, points: occluded, at: 0.1)
        XCTAssertFalse(measurement.reliable)
        XCTAssertFalse(measurement.pinching)
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.2), at: 0.12).pinching)
    }

    func testLongObservationGapRestartsStability() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        _ = detector.update(id: 0, points: points(ratio: 0.2), at: 0)
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.2), at: 1).pinching)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2), at: 1.06).pinching)
    }

    func testInvalidTinyPalmAndNonfinitePointsCannotTrigger() {
        var detector = PinchDetector()
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0, scale: 0.001), at: 0).reliable)
        var invalid = points(ratio: 0.2)
        invalid[.indexTip] = CGPoint(x: .nan, y: 0)
        XCTAssertFalse(detector.update(id: 0, points: invalid, at: 0).reliable)
    }

    func testOutOfOrderTimestampPreservesEstablishedState() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        _ = detector.update(id: 0, points: points(ratio: 0.2), at: 1)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2), at: 1.06).pinching)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.8), at: 0.5).pinching)
    }

    func testClosedHandReacquisitionCannotFalselyReportReliableRelease() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        _ = detector.update(id: 0, points: points(ratio: 0.2), at: 0)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.2), at: 0.06).pinching)
        detector.retain(ids: [])
        let reacquiring = detector.update(id: 0, points: points(ratio: 0.2), at: 1)
        XCTAssertFalse(reacquiring.reliable)
        let stable = detector.update(id: 0, points: points(ratio: 0.2), at: 1.06)
        XCTAssertTrue(stable.reliable)
        XCTAssertTrue(stable.pinching)
    }

    func testAmbiguousInitialDistanceIsUnreliableUntilClassified() {
        var detector = PinchDetector(configuration: immediateFilterConfiguration())
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.38), at: 0).reliable)
        XCTAssertFalse(detector.update(id: 0, points: points(ratio: 0.38), at: 0.1).reliable)
        XCTAssertTrue(detector.update(id: 0, points: points(ratio: 0.8), at: 0.2).reliable)
    }
}
