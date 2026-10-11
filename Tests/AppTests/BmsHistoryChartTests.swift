import ANTuRideDomain
import XCTest
@testable import ANTuRide

final class BmsHistoryChartTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testPowerKeepsMeasuredZeroAndNegativeValuesWithoutSubstitutingCurrent() {
        let points = BmsHistoryChartPoint.makePoints(history: [
            sample(0, power: 0, current: 99), sample(1, power: -250, current: 99),
            sample(2, power: 500, current: 99)
        ], metric: .power)
        XCTAssertEqual(points.map(\.value), [0, -250, 500])
        XCTAssertEqual(Set(points.map(\.series)).count, 1)
    }

    func testMissingAndNonFinitePowerBreakRatherThanBridgeTheLine() {
        let points = BmsHistoryChartPoint.makePoints(history: [
            sample(0, power: 10), sample(1, power: nil), sample(2, power: 20),
            sample(3, power: .nan), sample(4, power: 30),
            sample(5, power: .infinity), sample(6, power: 40)
        ], metric: .power)
        XCTAssertEqual(points.map(\.id), [0, 2, 4, 6])
        XCTAssertEqual(points.map(\.value), [10, 20, 30, 40])
        XCTAssertEqual(Set(points.map(\.series)).count, 4)
    }

    func testCurrentUsesAmperesIndependentlyOfMissingPower() {
        let points = BmsHistoryChartPoint.makePoints(history: [
            sample(0, power: nil, current: 0), sample(1, power: nil, current: -2.5),
            sample(2, power: 5_000, current: .nan), sample(3, power: nil, current: 3)
        ], metric: .current)
        XCTAssertEqual(points.map(\.value), [0, -2.5, 3])
        XCTAssertEqual(points.map(\.id), [0, 1, 3])
        XCTAssertEqual(points[0].series, points[1].series)
        XCTAssertNotEqual(points[1].series, points[2].series)
    }

    func testFiveSecondsIsContinuousButLargerGapStartsNewSeries() {
        let points = BmsHistoryChartPoint.makePoints(history: [
            sample(0, power: 10), sample(5, power: 20), sample(10.001, power: 30)
        ], metric: .power)
        XCTAssertEqual(points[0].series, points[1].series)
        XCTAssertNotEqual(points[1].series, points[2].series)
    }

    func testDuplicateAndBackwardTimesBreakWithoutSortingOrDroppingEvidence() {
        let history = [sample(2, power: 10), sample(2, power: 20),
                       sample(1, power: 30), sample(3, power: 40)]
        let points = BmsHistoryChartPoint.makePoints(history: history, metric: .power)
        XCTAssertEqual(points.map(\.timestamp), history.map(\.receivedAt))
        XCTAssertNotEqual(points[0].series, points[1].series)
        XCTAssertNotEqual(points[1].series, points[2].series)
        XCTAssertEqual(points[2].series, points[3].series)
    }

    func testEmptyAndSingleSampleDoNotCreateFakeValues() {
        XCTAssertTrue(BmsHistoryChartPoint.makePoints(history: [], metric: .power).isEmpty)
        XCTAssertTrue(BmsHistoryChartPoint.makePoints(history: [sample(0, power: nil)], metric: .power).isEmpty)
        let points = BmsHistoryChartPoint.makePoints(history: [sample(0, power: 42)], metric: .power)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.value, 42)
    }

    func testNonFiniteTimestampIsRejectedAndBreaksContinuity() {
        let points = BmsHistoryChartPoint.makePoints(history: [
            sample(0, power: 10), sample(.nan, power: 20), sample(2, power: 30)
        ], metric: .power)
        XCTAssertEqual(points.map(\.id), [0, 2])
        XCTAssertNotEqual(points[0].series, points[1].series)
    }

    private func sample(_ offset: TimeInterval, power: Double?, current: Double = 1) -> BmsSnapshot {
        BmsSnapshot(receivedAt: start.addingTimeInterval(offset), totalVoltage: 72,
                    current: current, soc: 50, capacityAh: 100, remainingAh: 50,
                    temperatures: [], mosTemperature: 0, balancerTemperature: 0,
                    cellVoltagesMillivolts: [], power: power, frameLength: 32)
    }
}
