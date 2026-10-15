import XCTest
@testable import ANTuRideDomain

final class LocationUpdateDemandTests: XCTestCase {
    func testForegroundSpeedDoesNotRequireTrip() {
        var demand = LocationUpdateDemand()
        XCTAssertFalse(demand.needsUpdates)
        demand.isForeground = true
        XCTAssertTrue(demand.needsUpdates)
        XCTAssertFalse(demand.allowsBackgroundUpdates)
    }

    func testStoppingTripKeepsForegroundSpeed() {
        var demand = LocationUpdateDemand()
        demand.isForeground = true
        demand.isRecordingTrip = true
        XCTAssertTrue(demand.allowsBackgroundUpdates)
        demand.isRecordingTrip = false
        XCTAssertTrue(demand.needsUpdates)
        XCTAssertFalse(demand.allowsBackgroundUpdates)
    }

    func testBackgroundWithoutTripStopsUpdates() {
        var demand = LocationUpdateDemand()
        demand.isForeground = true
        demand.isForeground = false
        XCTAssertFalse(demand.needsUpdates)
        XCTAssertFalse(demand.allowsBackgroundUpdates)
    }

    func testTripContinuesInBackgroundAndStopsWhenReleased() {
        var demand = LocationUpdateDemand()
        demand.isForeground = true
        demand.isRecordingTrip = true
        demand.isForeground = false
        XCTAssertTrue(demand.needsUpdates)
        XCTAssertTrue(demand.allowsBackgroundUpdates)
        demand.isRecordingTrip = false
        XCTAssertFalse(demand.needsUpdates)
        XCTAssertFalse(demand.allowsBackgroundUpdates)
    }
}
