import XCTest
@testable import GlacierBMSDomain

final class BmsSnapshotTests: XCTestCase {
    func testSnapshotExposesCellExtremes() {
        let snapshot = BmsSnapshot(totalVoltage: 70, current: 1, soc: 50, capacityAh: 100, remainingAh: 50, temperatures: [], mosTemperature: 20, balancerTemperature: 20, cellVoltagesMillivolts: [3500, 3490, 3510])
        XCTAssertEqual(snapshot.minCellVoltageMillivolts, 3490)
        XCTAssertEqual(snapshot.maxCellVoltageMillivolts, 3510)
        XCTAssertFalse(snapshot.isFreshCandidate)
    }
}
