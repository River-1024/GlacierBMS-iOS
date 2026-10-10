import XCTest
@testable import ANTuRideDomain

/// 行程记录器领域逻辑测试。
/// 覆盖规划 §4 阶段 2 三条验收红线的领域侧保证：
/// 暂停显式成段、缺口不伪造数据、前后台同一行程。
final class TripRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func fix(
        _ offset: TimeInterval,
        lat: Double = 30.0,
        lon: Double = 120.0,
        speed: Double = 5,
        accuracy: Double = 5
    ) -> GpsFix {
        GpsFix(
            timestamp: t0.addingTimeInterval(offset),
            latitude: lat,
            longitude: lon,
            speed: speed,
            horizontalAccuracy: accuracy
        )
    }

    /// 纬度 1 度 ≈ 111.19 km，用于构造确定距离。
    private let metersPerDegreeLat = 111_194.9

    func testStartCreatesForegroundSegmentAndRecordingState() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        // 速度无效（-1）迫使实现走 haversine 路径，距离可由纬度差静态确定。
        recorder.ingestLocation(fix(0, speed: -1))
        recorder.ingestLocation(fix(1, lat: 30.001, speed: -1))
        let trip = recorder.finish(at: t0.addingTimeInterval(2))
        XCTAssertEqual(recorder.state, .finished)
        let tripUnwrapped = try XCTUnwrap(trip)
        XCTAssertEqual(tripUnwrapped.segments.count, 1)
        XCTAssertEqual(tripUnwrapped.segments[0].kind, .foreground)
        XCTAssertEqual(tripUnwrapped.segments[0].locationCount, 2)
        // 0.001 度 ≈ 111.2 m（容差 5%）
        XCTAssertEqual(tripUnwrapped.totalDistanceMeters, metersPerDegreeLat * 0.001, accuracy: metersPerDegreeLat * 0.001 * 0.05)
    }

    func testSpeedIntegrationPreferredWhenSpeedsValid() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        // 两端速度均可信：里程 = 平均速度 5 m/s × 1 s，而非坐标差分。
        recorder.ingestLocation(fix(0, speed: 5))
        recorder.ingestLocation(fix(1, speed: 5))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(2)))
        XCTAssertEqual(trip.totalDistanceMeters, 5.0, accuracy: 1e-9)
    }

    func testInvalidFixCountedButNoDistance() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0, speed: -1))
        recorder.ingestLocation(fix(1, speed: -1, accuracy: 999)) // 精度超限
        recorder.ingestLocation(fix(2, lat: 95))                  // 纬度非法
        recorder.ingestLocation(fix(3, lat: 30.001, speed: -1))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(4)))
        XCTAssertEqual(trip.segments[0].invalidLocationCount, 2)
        XCTAssertEqual(trip.segments[0].locationCount, 2)
        XCTAssertEqual(trip.totalDistanceMeters, metersPerDegreeLat * 0.001, accuracy: metersPerDegreeLat * 0.001 * 0.05)
    }

    func testLongLocationGapInsertsGapSegmentWithoutRetroactiveDistance() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        // 间隔 30 秒（> maxLocationGap=10）：其间真实移动了 0.5 度，但不得追溯。
        recorder.ingestLocation(fix(30, lat: 30.5))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(31)))
        XCTAssertEqual(trip.segments.count, 3)
        XCTAssertEqual(trip.segments[0].kind, .foreground)
        XCTAssertEqual(trip.segments[0].distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(trip.segments[1].kind, .gap)
        XCTAssertEqual(trip.segments[1].distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(trip.segments[1].startedAt, t0)
        XCTAssertEqual(trip.segments[1].endedAt, t0.addingTimeInterval(30))
        XCTAssertEqual(trip.segments[2].kind, .foreground)
        // 触发缺口的定位点计入闭合段（segments[0] 共 2 点）；新段自该点重新起算。
        XCTAssertEqual(trip.segments[0].locationCount, 2)
        XCTAssertEqual(trip.segments[2].locationCount, 0)
    }

    func testPhaseSwitchKeepsSingleTripWithTwoSegments() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.setPhase(.background, at: t0.addingTimeInterval(5))
        recorder.ingestLocation(fix(6, lat: 30.001))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(10)))
        XCTAssertEqual(trip.segments.count, 2)
        XCTAssertEqual(trip.segments[0].kind, .foreground)
        XCTAssertEqual(trip.segments[1].kind, .background)
        XCTAssertEqual(trip.segments[1].locationCount, 1)
        // 同一行程：段边界连续，无缺口。
        XCTAssertEqual(trip.segments[0].endedAt, trip.segments[1].startedAt)
    }

    func testSuspendResumeProducesSuspendedSegmentAndContinuesTrip() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.suspend(at: t0.addingTimeInterval(5))
        XCTAssertEqual(recorder.state, .suspended)
        // 暂停期间的样本必须被忽略。
        recorder.ingestLocation(fix(6, lat: 30.5))
        recorder.ingestPowerWatts(500, at: t0.addingTimeInterval(7))
        recorder.resume(at: t0.addingTimeInterval(10))
        XCTAssertEqual(recorder.state, .recording)
        recorder.ingestLocation(fix(11, lat: 30.001))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(15)))
        let kinds = trip.segments.map(\.kind)
        XCTAssertEqual(kinds, [.foreground, .suspended, .foreground])
        let suspended = trip.segments[1]
        XCTAssertEqual(suspended.startedAt, t0.addingTimeInterval(5))
        XCTAssertEqual(suspended.endedAt, t0.addingTimeInterval(10))
        XCTAssertEqual(suspended.distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(suspended.energyWh, 0, accuracy: 0.001)
        // 暂停后的首个定位与暂停前基准重新配对，不产生缺口段。
        XCTAssertEqual(trip.segments[2].locationCount, 1)
    }

    func testEnergyAccumulatesOnlyForPairedFreshSamples() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(0)) // 首样本只登记
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(1)) // 1000W × 1s
        recorder.ingestPowerWatts(2000, at: t0.addingTimeInterval(3)) // 2000W × 2s
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(4)))
        // (1000*1 + 2000*2) / 3600 = 1.3889 Wh
        XCTAssertEqual(trip.totalEnergyWh, (1000.0 * 1 + 2000.0 * 2) / 3600, accuracy: 1e-9)
        XCTAssertEqual(trip.segments[0].energySampleCount, 2)
    }

    func testStaleBmsIntervalDoesNotFabricateEnergy() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(0))
        // BLE 断开 60 秒后恢复：间隔超限，不得补算 60 秒能耗。
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(60))
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(61))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(62)))
        XCTAssertEqual(trip.totalEnergyWh, 1000.0 * 1 / 3600, accuracy: 1e-9)
        XCTAssertEqual(trip.segments[0].energySampleCount, 1)
    }

    func testIngestSnapshotUsesPowerOnlyWhenPresent() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        let noPower = BmsSnapshot(
            receivedAt: t0, totalVoltage: 66, current: 0, soc: 50,
            capacityAh: 20, remainingAh: 10, temperatures: [],
            mosTemperature: 0, balancerTemperature: 0, cellVoltagesMillivolts: []
        )
        let withPower = BmsSnapshot(
            receivedAt: t0.addingTimeInterval(1), totalVoltage: 66, current: 15, soc: 50,
            capacityAh: 20, remainingAh: 10, temperatures: [],
            mosTemperature: 0, balancerTemperature: 0, cellVoltagesMillivolts: [], power: 990
        )
        recorder.ingestSnapshot(noPower)   // power nil → 忽略
        recorder.ingestSnapshot(withPower) // 首个有效功率 → 只登记
        recorder.ingestSnapshot(BmsSnapshot(
            receivedAt: t0.addingTimeInterval(2), totalVoltage: 66, current: 15, soc: 50,
            capacityAh: 20, remainingAh: 10, temperatures: [],
            mosTemperature: 0, balancerTemperature: 0, cellVoltagesMillivolts: [], power: 990
        ))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(trip.totalEnergyWh, 990.0 * 1 / 3600, accuracy: 1e-9)
    }

    func testLifecycleGuards() throws {
        var recorder = TripRecorder()
        // 未 start：一切输入被忽略。
        recorder.ingestLocation(fix(0))
        recorder.ingestPowerWatts(100, at: t0)
        recorder.suspend(at: t0)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNil(recorder.finish(at: t0))
        // start 幂等：重复 start 不重置。
        recorder.start(at: t0)
        recorder.setPhase(.foreground, at: t0) // 同相位：no-op
        recorder.suspend(at: t0.addingTimeInterval(1))
        recorder.suspend(at: t0.addingTimeInterval(2)) // 重复 suspend：no-op
        recorder.resume(at: t0.addingTimeInterval(3))
        recorder.resume(at: t0.addingTimeInterval(4)) // recording 态 resume：no-op
        recorder.start(at: t0.addingTimeInterval(5))  // recording 态 start：no-op
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(6)))
        XCTAssertNil(recorder.finish(at: t0.addingTimeInterval(7))) // 重复 finish：nil
        XCTAssertEqual(trip.segments.count, 3) // foreground(0-1) + suspended(1-3) + foreground(3-6)
        XCTAssertEqual(trip.segments[2].startedAt, t0.addingTimeInterval(3))
        XCTAssertEqual(trip.segments[2].endedAt, t0.addingTimeInterval(6))
    }

    func testTripTotalsMatchSegmentSums() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestLocation(fix(1, lat: 30.001))
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(0))
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(1))
        recorder.suspend(at: t0.addingTimeInterval(5))
        recorder.resume(at: t0.addingTimeInterval(8))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(9)))
        XCTAssertEqual(trip.totalDistanceMeters, trip.segments.reduce(0) { $0 + $1.distanceMeters }, accuracy: 1e-9)
        XCTAssertEqual(trip.totalEnergyWh, trip.segments.reduce(0) { $0 + $1.energyWh }, accuracy: 1e-9)
        XCTAssertEqual(trip.startedAt, t0)
        XCTAssertEqual(trip.endedAt, t0.addingTimeInterval(9))
        XCTAssertEqual(trip.durationSeconds, 9, accuracy: 1e-9)
    }
}
