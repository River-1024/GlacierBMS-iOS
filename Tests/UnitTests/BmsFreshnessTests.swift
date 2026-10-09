import XCTest
@testable import ANTuRideDomain

final class BmsFreshnessTests: XCTestCase {
    private func makeSnapshot(receivedAt: Date) -> BmsSnapshot {
        BmsSnapshot(
            receivedAt: receivedAt,
            totalVoltage: 70,
            current: 0,
            soc: 50,
            capacityAh: 100,
            remainingAh: 50,
            temperatures: [],
            mosTemperature: 20,
            balancerTemperature: 20,
            cellVoltagesMillivolts: [3500]
        )
    }

    func testNoDataWhenSnapshotMissing() {
        XCTAssertEqual(BmsFreshnessEvaluator().evaluate(snapshot: nil, now: Date()), .noData)
    }

    func testFreshWithinWindow() {
        let now = Date()
        let snapshot = makeSnapshot(receivedAt: now.addingTimeInterval(-2))
        let evaluation = BmsFreshnessEvaluator(freshWindow: 5).evaluate(snapshot: snapshot, now: now)
        XCTAssertEqual(evaluation.level, .fresh)
        XCTAssertEqual(evaluation.ageSeconds ?? -1, 2, accuracy: 0.001)
    }

    func testStaleBeyondWindow() {
        let now = Date()
        let snapshot = makeSnapshot(receivedAt: now.addingTimeInterval(-6))
        XCTAssertEqual(BmsFreshnessEvaluator(freshWindow: 5).evaluate(snapshot: snapshot, now: now).level, .stale)
    }

    func testFutureTimestampClampsToZero() {
        let now = Date()
        let snapshot = makeSnapshot(receivedAt: now.addingTimeInterval(10))
        let evaluation = BmsFreshnessEvaluator(freshWindow: 5).evaluate(snapshot: snapshot, now: now)
        XCTAssertEqual(evaluation.level, .fresh)
        XCTAssertEqual(evaluation.ageSeconds ?? -1, 0, accuracy: 0.001)
    }
}
