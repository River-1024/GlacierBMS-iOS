import ANTuRideDomain
import XCTest
@testable import ANTuRide

final class TripFormattersTests: XCTestCase {
    func testDistanceUnitsAndInvalidValues() {
        XCTAssertEqual(TripFormatters.distance(0, locationCount: 0), "--")
        XCTAssertEqual(TripFormatters.distance(0, locationCount: 1), "0 m")
        XCTAssertEqual(TripFormatters.distance(999), "999 m")
        XCTAssertEqual(TripFormatters.distance(1250), "1.25 km")
        XCTAssertEqual(TripFormatters.distance(.nan), "--")
        XCTAssertEqual(TripFormatters.distance(-1), "--")
    }

    func testMissingEnergyIsNotZeroAndChargingIsNegative() {
        XCTAssertEqual(TripFormatters.energy(0, sampleCount: 0), "-- Wh")
        XCTAssertEqual(TripFormatters.energy(0, sampleCount: 1), "0.0 Wh")
        XCTAssertEqual(TripFormatters.energy(-2.5, sampleCount: 2), "-2.5 Wh")
        XCTAssertEqual(TripFormatters.energy(.infinity, sampleCount: 2), "-- Wh")
    }

    func testDurationIncludesSecondsAndHours() {
        XCTAssertEqual(TripFormatters.duration(5), "0m 05s")
        XCTAssertEqual(TripFormatters.duration(65), "1m 05s")
        XCTAssertEqual(TripFormatters.duration(3661), "1h 01m 01s")
        XCTAssertEqual(TripFormatters.duration(-1), "--")
        XCTAssertEqual(TripFormatters.duration(.infinity), "--")
    }

    func testAllSegmentKindsHaveDistinctLabels() {
        XCTAssertEqual(Set(TripSegmentKind.allCases.map(TripFormatters.kind)).count, 4)
        XCTAssertEqual(TripFormatters.kind(.suspended), "暂停")
        XCTAssertEqual(TripFormatters.kind(.gap), "数据缺口")
    }
}
