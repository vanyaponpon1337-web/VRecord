import CoreGraphics
import XCTest
@testable import VRecord

final class HandCoordinateConverterTests: XCTestCase {
    func testCenterStaysAtCenterWithAspectFillCrop() {
        let result = HandCoordinateConverter.viewPoint(
            for: NormalizedPoint(x: 0.5, y: 0.5),
            sourceAspectRatio: 16 / 9,
            in: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(result.x, 50, accuracy: 0.001)
        XCTAssertEqual(result.y, 50, accuracy: 0.001)
    }

    func testVisionBottomLeftYAxisIsFlippedForSwiftUI() {
        let result = HandCoordinateConverter.viewPoint(
            for: NormalizedPoint(x: 0.5, y: 1),
            sourceAspectRatio: 1,
            in: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }
}
