import XCTest
@testable import Browser_Setu

final class SmartSelectionTests: XCTestCase {
    func testDistanceWeightAndTemperatureConvert() {
        XCTAssertEqual(UnitConverter.conversions(in: "a 10 km run").first?.result, "6.21 mi")
        XCTAssertEqual(UnitConverter.conversions(in: "Weighs 5 kg").first?.result, "11.02 lb")
        XCTAssertEqual(UnitConverter.conversions(in: "It is 100°C outside").first?.result, "212 °F")
        XCTAssertEqual(UnitConverter.conversions(in: "Drive at 60 mph").first?.result, "96.56 km/h")
    }

    func testThousandsSeparatorAndNoFalsePositives() {
        XCTAssertEqual(UnitConverter.conversions(in: "1,000 km").first?.result, "621.37 mi")
        XCTAssertTrue(UnitConverter.conversions(in: "3 apples and 2 dogs").isEmpty)
        XCTAssertTrue(UnitConverter.conversions(in: "Chapter 5 m is a typo").isEmpty)
    }
}
