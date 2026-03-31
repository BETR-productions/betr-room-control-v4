@testable import FeatureUI
import XCTest

final class OutputMeterScaleTests: XCTestCase {
    func testNegativeLevelClampsToZeroFill() {
        XCTAssertEqual(OutputMeterScale.normalizedFillLevel(forLinearLevel: -0.5), 0)
    }

    func testZeroLevelMapsToZeroFill() {
        XCTAssertEqual(OutputMeterScale.normalizedFillLevel(forLinearLevel: 0), 0)
    }

    func testMinusSixtyDbfsMapsToZeroFill() {
        XCTAssertEqual(OutputMeterScale.normalizedFillLevel(forLinearLevel: 0.001), 0, accuracy: 0.0001)
    }

    func testMinusTwentyDbfsMapsAboveLinearTenPercent() {
        let fill = OutputMeterScale.normalizedFillLevel(forLinearLevel: 0.1)
        XCTAssertGreaterThan(fill, 0.6)
        XCTAssertLessThan(fill, 0.7)
    }

    func testUnityLevelMapsToFullScale() {
        XCTAssertEqual(OutputMeterScale.normalizedFillLevel(forLinearLevel: 1), 1)
    }

    func testAboveUnityClampsToFullScale() {
        XCTAssertEqual(OutputMeterScale.normalizedFillLevel(forLinearLevel: 1.5), 1)
    }
}
