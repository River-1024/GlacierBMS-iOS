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
        // 无效定位打断配对，恢复首点不能跨过无效区间补算。
        XCTAssertEqual(trip.totalDistanceMeters, 0)
        XCTAssertNil(trip.samples.last?.locationIntervalSeconds)
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
        // 缺口后的首点属于新段，计数和逐点时间均不得归入旧段。
        XCTAssertEqual(trip.segments[0].locationCount, 1)
        XCTAssertEqual(trip.segments[2].locationCount, 1)
        XCTAssertEqual(trip.segments[2].samples?.first?.timestamp, t0.addingTimeInterval(30))
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
        recorder.ingestSnapshot(noPower)   // power nil → 无效事件，不积分
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

    /// 实时段视图：闭合段 + 进行中段快照。
    func testLiveSegmentsIncludesOpenSegment() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0, speed: -1))
        recorder.ingestLocation(fix(1, lat: 30.001, speed: -1))
        let live = recorder.liveSegments
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].locationCount, 2)
        XCTAssertEqual(live[0].distanceMeters, metersPerDegreeLat * 0.001, accuracy: metersPerDegreeLat * 0.001 * 0.05)
        // finish 后 liveSegments 与 segments 一致。
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(2)))
        XCTAssertEqual(recorder.liveSegments.count, trip.segments.count)
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
    func testPhaseSwitchResetsPairingAndDoesNotCreateReversedGap() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestPowerWatts(1000, at: t0)
        recorder.setPhase(.background, at: t0.addingTimeInterval(5))
        recorder.ingestLocation(fix(20, lat: 30.001))
        recorder.ingestLocation(fix(21, lat: 30.002))
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(20))
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(21))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(22)))
        XCTAssertEqual(trip.segments.map(\.kind), [.foreground, .background])
        XCTAssertTrue(trip.segments.allSatisfy { $0.endedAt >= $0.startedAt })
        XCTAssertEqual(trip.segments[0].endedAt, trip.segments[1].startedAt)
        XCTAssertEqual(trip.segments[1].energySampleCount, 1)
        XCTAssertEqual(trip.totalEnergyWh, 1000.0 / 3600, accuracy: 1e-9)
    }

    func testPhaseSwitchDoesNotIntegrateAcrossBoundary() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0, speed: 10))
        recorder.ingestPowerWatts(1000, at: t0)
        recorder.setPhase(.background, at: t0.addingTimeInterval(1))
        recorder.ingestLocation(fix(2, speed: 10))
        recorder.ingestPowerWatts(1000, at: t0.addingTimeInterval(2))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(trip.totalDistanceMeters, 0)
        XCTAssertEqual(trip.totalEnergyWh, 0)
        XCTAssertEqual(trip.segments[1].energySampleCount, 0)
    }

    private func snapshot(_ offset: TimeInterval, power: Double? = 660,
                          voltage: Double = 66, current: Double = 10) -> BmsSnapshot {
        BmsSnapshot(receivedAt: t0.addingTimeInterval(offset), totalVoltage: voltage,
            current: current, soc: 50, capacityAh: 20, remainingAh: 10, temperatures: [],
            mosTemperature: 0, balancerTemperature: 0, cellVoltagesMillivolts: [], power: power)
    }

    private func archive(_ samples: [TripSample]?, end: TimeInterval = 60,
                         kind: TripSegmentKind = .foreground) -> Trip {
        Trip(startedAt: t0, endedAt: t0.addingTimeInterval(end), segments: [
            TripSegment(kind: kind, startedAt: t0, endedAt: t0.addingTimeInterval(end),
                distanceMeters: 123, energyWh: 456, locationCount: 1,
                energySampleCount: 1, invalidLocationCount: 0, samples: samples)
        ])
    }

    func testLegacyJSONAndPublicInitializersRemainCompatible() throws {
        let legacy = archive(nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        segments[0].removeValue(forKey: "samples")
        object["segments"] = segments
        let decoded = try JSONDecoder().decode(Trip.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, legacy)
        XCTAssertNil(decoded.segments[0].samples)
        XCTAssertTrue(decoded.samples.isEmpty)
        XCTAssertTrue(decoded.chartSegments(for: .speed).isEmpty)
        let window = try XCTUnwrap(decoded.windowSummaries(minutes: 1).first)
        XCTAssertEqual(window.coverageRatio, 0)
        XCTAssertNil(window.distanceMeters) // 段总计不能伪装成逐点覆盖。
        XCTAssertNil(window.energyWh)
        segments[0]["samples"] = NSNull()
        object["segments"] = segments
        let nullSamples = try JSONDecoder().decode(Trip.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(nullSamples, legacy)
        // 所有旧公开 init 参数保持可用。
        let oldSegment = TripSegment(kind: .foreground, startedAt: t0, endedAt: t0,
            distanceMeters: 0, energyWh: 0, locationCount: 0, energySampleCount: 0, invalidLocationCount: 0)
        XCTAssertTrue(Trip(startedAt: t0, segments: [oldSegment]).samples.isEmpty)
    }

    func testTimestampOnlySampleDecodesWithUnknownSources() throws {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": t0.timeIntervalSinceReferenceDate])
        let sample = try JSONDecoder().decode(TripSample.self, from: data)
        XCTAssertEqual(sample.timestamp, t0)
        XCTAssertNil(sample.gpsValid)
        XCTAssertNil(sample.bmsValid)
        XCTAssertNil(sample.energyIntervalSeconds)
        XCTAssertNil(TripMetric.speed.value(in: sample))
        XCTAssertNil(TripMetric.power.value(in: sample))
    }

    func testSamplesSurviveLiveCheckpointServiceReconstructionAndJSONRoundTrip() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestSnapshot(snapshot(0, power: -198, current: -3))
        recorder.ingestLocation(fix(1))
        recorder.ingestSnapshot(snapshot(1, power: -198, current: -3))
        let checkpoint = Trip(startedAt: t0, segments: recorder.liveSegments)
        XCTAssertEqual(checkpoint.samples.count, 4)
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(2)))
        // 模拟现有 stopTrip 仅以 segments 重建，不能丢点。
        let rebuilt = Trip(id: trip.id, startedAt: trip.startedAt, endedAt: trip.endedAt, segments: trip.segments)
        let restored = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(rebuilt))
        XCTAssertEqual(restored, trip)
        let gps = try XCTUnwrap(restored.samples.first)
        XCTAssertEqual(gps.gpsValid, true)
        XCTAssertNil(gps.bmsValid)
        XCTAssertNil(gps.powerWatts)
        XCTAssertEqual(TripMetric.speed.value(in: gps), 18)
        let bms = restored.samples[1]
        XCTAssertNil(bms.gpsValid)
        XCTAssertNil(bms.speedMetersPerSecond)
        XCTAssertEqual(bms.bmsValid, true)
        XCTAssertEqual(bms.voltageVolts, 66)
        XCTAssertEqual(bms.currentAmps, -3)
        XCTAssertEqual(TripMetric.power.value(in: bms), -198)
        XCTAssertEqual(restored.samples[2].locationIntervalSeconds, 1)
        XCTAssertEqual(restored.samples[3].energyIntervalSeconds, 1)
        XCTAssertEqual(restored.totalEnergyWh, -198.0 / 3600, accuracy: 1e-9)
    }

    func testMissingSnapshotPowerBreaksIntegrationRatherThanHoldingLastValue() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestSnapshot(snapshot(0))
        recorder.ingestSnapshot(snapshot(1, power: nil))
        recorder.ingestSnapshot(snapshot(2))
        recorder.ingestSnapshot(snapshot(3))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(4)))
        XCTAssertEqual(trip.totalEnergyWh, 660.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(trip.samples[1].bmsValid, false)
        XCTAssertNil(trip.samples[2].energyIntervalSeconds)
        XCTAssertEqual(trip.chartSegments(for: .power).map(\.count), [1, 2])
        XCTAssertEqual(trip.windowSummaries(minutes: 1).first?.bmsCoveredSeconds, 1)
    }

    func testNonfiniteInputsAreInvalidAndJSONEncodable() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestLocation(fix(1, lat: .nan))
        recorder.ingestLocation(fix(2, speed: .infinity, accuracy: .infinity))
        recorder.ingestLocation(fix(3))
        recorder.ingestPowerWatts(100, at: t0)
        recorder.ingestPowerWatts(.nan, at: t0.addingTimeInterval(1))
        recorder.ingestSnapshot(snapshot(2, voltage: .infinity))
        recorder.ingestSnapshot(snapshot(3))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(4)))
        XCTAssertEqual(trip.totalEnergyWh, 0)
        XCTAssertEqual(trip.totalDistanceMeters, 0)
        XCTAssertEqual(trip.segments[0].invalidLocationCount, 2)
        XCTAssertNil(trip.samples[1].latitude)
        XCTAssertNil(trip.samples[2].speedMetersPerSecond)
        XCTAssertEqual(try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip)), trip)
    }

    func testDuplicateAndOutOfOrderInputsDoNotMovePairingBackward() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        for offset in [2.0, 1.0, 2.0, 3.0] {
            recorder.ingestLocation(fix(offset))
            recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(offset))
        }
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(4)))
        XCTAssertEqual(trip.samples.count, 4)
        XCTAssertEqual(trip.totalDistanceMeters, 5)
        XCTAssertEqual(trip.totalEnergyWh, 1)
    }

    func testLocationGapDoesNotCarryBmsPairingOrBackdateExistingBmsEvidence() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(28))
        recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(29))
        recorder.ingestLocation(fix(30))
        recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(31))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(32)))
        XCTAssertEqual(trip.segments.map(\.kind), [.foreground, .gap, .foreground])
        XCTAssertEqual(trip.segments[1].startedAt, t0.addingTimeInterval(29))
        XCTAssertEqual(trip.totalEnergyWh, 1) // 31 秒首点不能与旧段 29 秒配对。
        XCTAssertNil(trip.samples.last?.energyIntervalSeconds)
        XCTAssertTrue(trip.segments.allSatisfy { segment in
            (segment.samples ?? []).allSatisfy { $0.timestamp >= segment.startedAt && $0.timestamp <= segment.endedAt }
        })
        XCTAssertEqual(trip.windowSummaries(minutes: 1).first?.bmsCoveredSeconds, 1)
    }

    func testPausedInputsAreNotSavedAndPhaseBoundariesBreakCharts() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestLocation(fix(1))
        recorder.ingestSnapshot(snapshot(0))
        recorder.ingestSnapshot(snapshot(1))
        recorder.suspend(at: t0.addingTimeInterval(2))
        recorder.ingestLocation(fix(3))
        recorder.ingestSnapshot(snapshot(3))
        recorder.resume(at: t0.addingTimeInterval(4))
        recorder.ingestLocation(fix(4))
        recorder.ingestSnapshot(snapshot(4))
        recorder.setPhase(.background, at: t0.addingTimeInterval(5))
        recorder.ingestLocation(fix(5))
        recorder.ingestSnapshot(snapshot(5))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(6)))
        XCTAssertEqual(trip.samples.count, 8)
        XCTAssertEqual(trip.chartSegments(for: .speed).map(\.count), [2, 1, 1])
        XCTAssertEqual(trip.chartSegments(for: .voltage).map(\.count), [2, 1, 1])
        let window = try XCTUnwrap(trip.windowSummaries(minutes: 1).first)
        XCTAssertEqual(window.jointlyCoveredSeconds, 1)
        XCTAssertEqual(window.coverageRatio, 1.0 / 6, accuracy: 1e-9)
    }

    func testChartsSeparateInvalidValuesAndStaleIntervalsWithoutMixingSources() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestLocation(fix(0))
        recorder.ingestSnapshot(snapshot(0))
        recorder.ingestLocation(fix(1))
        recorder.ingestSnapshot(snapshot(1))
        recorder.ingestLocation(fix(2, speed: -1)) // 坐标有效，速度曲线断线。
        recorder.ingestLocation(fix(3))
        recorder.ingestSnapshot(snapshot(9)) // BMS 间隔超限，GPS 不受影响。
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(10)))
        XCTAssertEqual(trip.chartSegments(for: .speed).map(\.count), [2, 1])
        XCTAssertEqual(trip.chartSegments(for: .power).map(\.count), [2, 1])
        XCTAssertEqual(trip.chartSegments(for: .current).map(\.count), [2, 1])
        XCTAssertNil(TripMetric.speed.value(in: TripSample(timestamp: t0, gpsValid: true, speedMetersPerSecond: .infinity)))
        XCTAssertNil(TripMetric.power.value(in: TripSample(timestamp: t0, bmsValid: false, powerWatts: 100)))
    }

    func testAllSupportedWindowsConserveEvidenceAndUseActualTailDuration() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        for second in 0...601 {
            recorder.ingestLocation(fix(Double(second), speed: 10))
            recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(Double(second)))
        }
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(601)))
        for minutes in Trip.supportedWindowMinutes {
            let windows = trip.windowSummaries(minutes: minutes)
            XCTAssertEqual(windows.count, Int(ceil(601.0 / Double(minutes * 60))))
            let width = Double(minutes * 60)
            XCTAssertEqual(windows.last?.durationSeconds, 601 - floor(600 / width) * width)
            XCTAssertEqual(windows.reduce(0) { $0 + ($1.distanceMeters ?? 0) }, 6010, accuracy: 1e-9)
            XCTAssertEqual(windows.reduce(0) { $0 + ($1.energyWh ?? 0) }, 601, accuracy: 1e-9)
            for window in windows {
                XCTAssertEqual(window.coverageRatio, 1, accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(window.averageSpeedKmh), 36, accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(window.averagePowerWatts), 3600, accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(window.whPerKm), 100, accuracy: 1e-9)
            }
        }
    }

    func testCrossWindowClippingRespectsConfiguredRecorderThresholds() throws {
        var recorder = TripRecorder(maxLocationGap: 70, maxBmsSampleInterval: 70)
        recorder.start(at: t0)
        recorder.ingestLocation(fix(55, speed: 10))
        recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(55))
        recorder.ingestLocation(fix(65, speed: 10))
        recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(65))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(65)))
        let windows = trip.windowSummaries(minutes: 1)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].jointlyCoveredSeconds, 5)
        XCTAssertEqual(windows[1].jointlyCoveredSeconds, 5)
        XCTAssertEqual(windows[0].coverageRatio, 5.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(windows[1].coverageRatio, 1)
        XCTAssertEqual(windows[0].distanceMeters, 50)
        XCTAssertEqual(windows[1].distanceMeters, 50)
        XCTAssertEqual(windows[0].energyWh, 5)
        XCTAssertEqual(windows[1].energyWh, 5)
        XCTAssertEqual(trip.chartSegments(for: .speed).map(\.count), [2])
    }

    func testJointCoverageUsesIntersectionNotMinimumOfSourceDurations() throws {
        let samples = [
            TripSample(timestamp: t0.addingTimeInterval(10), gpsValid: true,
                locationIntervalSeconds: 10, distanceMeters: 100),
            TripSample(timestamp: t0.addingTimeInterval(15), bmsValid: true,
                energyIntervalSeconds: 10, energyWh: 2)
        ]
        let window = try XCTUnwrap(archive(samples).windowSummaries(minutes: 1).first)
        XCTAssertEqual(window.gpsCoveredSeconds, 10)
        XCTAssertEqual(window.bmsCoveredSeconds, 10)
        XCTAssertEqual(window.jointlyCoveredSeconds, 5)
        XCTAssertEqual(window.jointDistanceMeters, 50)
        XCTAssertEqual(window.jointEnergyWh, 1)
        XCTAssertEqual(try XCTUnwrap(window.whPerKm), 20, accuracy: 1e-9)
        let disjoint = [samples[0], TripSample(timestamp: t0.addingTimeInterval(30),
            bmsValid: true, energyIntervalSeconds: 10, energyWh: 2)]
        let other = try XCTUnwrap(archive(disjoint).windowSummaries(minutes: 1).first)
        XCTAssertEqual(other.jointlyCoveredSeconds, 0)
        XCTAssertNil(other.whPerKm)
    }

    func testZeroEnergyChargingAndMissingEvidenceHaveDistinctSemantics() throws {
        for amount in [0.0, -2.0] {
            let samples = [TripSample(timestamp: t0.addingTimeInterval(10), gpsValid: true, bmsValid: true,
                locationIntervalSeconds: 10, distanceMeters: 100, energyIntervalSeconds: 10, energyWh: amount)]
            let window = try XCTUnwrap(archive(samples).windowSummaries(minutes: 1).first)
            XCTAssertEqual(window.energyWh, amount)
            XCTAssertEqual(try XCTUnwrap(window.whPerKm), amount * 10, accuracy: 1e-9)
            XCTAssertEqual(window.coverageRatio, 10.0 / 60, accuracy: 1e-9)
        }
        let pointsWithoutIntervals = [TripSample(timestamp: t0, gpsValid: true, bmsValid: true,
            speedMetersPerSecond: 5, powerWatts: 100)]
        let missing = try XCTUnwrap(archive(pointsWithoutIntervals).windowSummaries(minutes: 1).first)
        XCTAssertNil(missing.energyWh)
        XCTAssertNil(missing.distanceMeters)
        XCTAssertEqual(missing.coverageRatio, 0)
        let stationary = [TripSample(timestamp: t0.addingTimeInterval(10), gpsValid: true, bmsValid: true,
            locationIntervalSeconds: 10, distanceMeters: 0, energyIntervalSeconds: 10, energyWh: 2)]
        let stopped = try XCTUnwrap(archive(stationary).windowSummaries(minutes: 1).first)
        XCTAssertEqual(stopped.distanceMeters, 0)
        XCTAssertNil(stopped.whPerKm)
    }

    func testCorruptOverlappingOutOfBoundsAndSuspendedEvidenceDoesNotCreateCoverage() throws {
        let samples = [
            TripSample(timestamp: t0.addingTimeInterval(10), gpsValid: true, locationIntervalSeconds: 10, distanceMeters: 100),
            TripSample(timestamp: t0.addingTimeInterval(15), gpsValid: true, locationIntervalSeconds: 10, distanceMeters: 999),
            TripSample(timestamp: t0.addingTimeInterval(20), bmsValid: true, energyIntervalSeconds: .infinity, energyWh: 2),
            TripSample(timestamp: t0.addingTimeInterval(30), bmsValid: false, energyIntervalSeconds: 5, energyWh: 999),
            TripSample(timestamp: t0.addingTimeInterval(70), gpsValid: true, locationIntervalSeconds: 5, distanceMeters: 999)
        ]
        let window = try XCTUnwrap(archive(samples).windowSummaries(minutes: 1).first)
        XCTAssertEqual(window.distanceMeters, 100)
        XCTAssertEqual(window.gpsCoveredSeconds, 10)
        XCTAssertNil(window.energyWh)
        let suspended = try XCTUnwrap(archive(samples, kind: .suspended).windowSummaries(minutes: 1).first)
        XCTAssertEqual(suspended.gpsCoveredSeconds, 0)
        XCTAssertTrue(archive(samples, kind: .gap).chartSegments(for: .speed).isEmpty)
        XCTAssertTrue(archive(samples, end: 0).windowSummaries(minutes: 1).isEmpty)
        XCTAssertTrue(archive(samples).windowSummaries(minutes: 2).isEmpty)
        XCTAssertTrue(archive(samples, end: 60 * 100_001).windowSummaries(minutes: 1).isEmpty)
    }


    func testInitialSnapshotAndGpsOlderThanTripStartNeverEnterHistoryOrPairing() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestSnapshot(snapshot(-1))
        recorder.ingestLocation(fix(-1))
        XCTAssertTrue(recorder.liveSegments.flatMap { $0.samples ?? [] }.isEmpty)
        recorder.ingestSnapshot(snapshot(1))
        recorder.ingestLocation(fix(1))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(2)))
        XCTAssertEqual(trip.samples.count, 2)
        XCTAssertTrue(trip.samples.allSatisfy { $0.timestamp >= trip.startedAt })
        XCTAssertEqual(trip.totalEnergyWh, 0)
        XCTAssertEqual(trip.totalDistanceMeters, 0)
        XCTAssertNil(trip.samples[0].energyIntervalSeconds)
        XCTAssertNil(trip.samples[1].locationIntervalSeconds)
    }

    func testStaleSnapshotFromPriorPhaseCannotSeedNewPhase() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestSnapshot(snapshot(0))
        recorder.setPhase(.background, at: t0.addingTimeInterval(10))
        recorder.ingestSnapshot(snapshot(9))
        recorder.ingestSnapshot(snapshot(11))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(12)))
        XCTAssertEqual(trip.segments[1].samples?.count, 1)
        XCTAssertEqual(trip.totalEnergyWh, 0)
        XCTAssertNil(trip.segments[1].samples?.first?.energyIntervalSeconds)
    }


    func testPowerUsesCurrentSampleRightRectangleNotTrapezoid() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        recorder.ingestPowerWatts(1000, at: t0)
        recorder.ingestPowerWatts(2000, at: t0.addingTimeInterval(1))
        recorder.ingestPowerWatts(-500, at: t0.addingTimeInterval(2))
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(try XCTUnwrap(trip.samples[1].energyWh), 2000.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(trip.samples[2].energyWh), -500.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(trip.totalEnergyWh, 1500.0 / 3600, accuracy: 1e-9)
        let window = try XCTUnwrap(trip.windowSummaries(minutes: 1).first)
        XCTAssertEqual(try XCTUnwrap(window.energyWh), trip.totalEnergyWh, accuracy: 1e-9)
        XCTAssertEqual(window.bmsCoveredSeconds, 2)
        XCTAssertEqual(try XCTUnwrap(window.averagePowerWatts), 750, accuracy: 1e-9)
        XCTAssertEqual(window.bmsCoverageRatio, 2.0 / 3, accuracy: 1e-9)
        XCTAssertNil(window.whPerKm) // 只有 BMS，不能生成 GPS/BMS 共同能耗。
    }

    func testWindowCoverageNeverIntegratesAcrossPhaseOrSuspensionBoundaries() throws {
        var recorder = TripRecorder()
        recorder.start(at: t0)
        for offset in [0.0, 1.0] {
            recorder.ingestLocation(fix(offset))
            recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(offset))
        }
        recorder.setPhase(.background, at: t0.addingTimeInterval(2))
        for offset in [3.0, 4.0] {
            recorder.ingestLocation(fix(offset))
            recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(offset))
        }
        recorder.suspend(at: t0.addingTimeInterval(5))
        recorder.resume(at: t0.addingTimeInterval(10))
        for offset in [11.0, 12.0] {
            recorder.ingestLocation(fix(offset))
            recorder.ingestPowerWatts(3600, at: t0.addingTimeInterval(offset))
        }
        let trip = try XCTUnwrap(recorder.finish(at: t0.addingTimeInterval(60)))
        let window = try XCTUnwrap(trip.windowSummaries(minutes: 1).first)
        XCTAssertEqual(trip.segments.map(\.kind), [.foreground, .background, .suspended, .background])
        XCTAssertEqual(trip.totalEnergyWh, 3)
        XCTAssertEqual(window.bmsCoveredSeconds, 3)
        XCTAssertEqual(window.gpsCoveredSeconds, 3)
        XCTAssertEqual(window.jointlyCoveredSeconds, 3)
        XCTAssertEqual(window.coverageRatio, 3.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(window.distanceMeters, 15)
        XCTAssertEqual(window.energyWh, 3)
    }

    func testWindowCoverageRejectsIntervalsReachingIntoPriorSegment() throws {
        let samples = [
            TripSample(timestamp: t0.addingTimeInterval(21), gpsValid: true, bmsValid: true,
                locationIntervalSeconds: 5, distanceMeters: 999, energyIntervalSeconds: 5, energyWh: 999),
            TripSample(timestamp: t0.addingTimeInterval(22), gpsValid: true, bmsValid: true,
                locationIntervalSeconds: 1, distanceMeters: 5, energyIntervalSeconds: 1, energyWh: 1)
        ]
        let trip = Trip(startedAt: t0, endedAt: t0.addingTimeInterval(60), segments: [
            TripSegment(kind: .foreground, startedAt: t0, endedAt: t0.addingTimeInterval(20),
                distanceMeters: 0, energyWh: 0, locationCount: 0, energySampleCount: 0, invalidLocationCount: 0),
            TripSegment(kind: .background, startedAt: t0.addingTimeInterval(20), endedAt: t0.addingTimeInterval(60),
                distanceMeters: 5, energyWh: 1, locationCount: 2, energySampleCount: 1,
                invalidLocationCount: 0, samples: samples)
        ])
        let window = try XCTUnwrap(trip.windowSummaries(minutes: 1).first)
        XCTAssertEqual(window.jointlyCoveredSeconds, 1)
        XCTAssertEqual(window.distanceMeters, 5)
        XCTAssertEqual(window.energyWh, 1)
    }

}
