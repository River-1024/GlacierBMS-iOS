import ANTuRideDomain
import Foundation
import XCTest
@testable import ANTuRide

final class RangeServiceTests: XCTestCase {
    private let deviceA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let deviceB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @MainActor
    func testUnboundServiceHasExplicitEmptyStateWithoutInventedCapacity() throws {
        try withService { service, _ in
            service.setDeviceID(nil)
            XCTAssertEqual(service.status, .disconnected)
            XCTAssertNil(service.prediction)
            XCTAssertNil(service.effectiveWhPerKm)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertTrue(service.reasonText.contains("设备 ID"))
            XCTAssertFalse(service.updateNominalCapacityAh(100))
        }
    }

    @MainActor
    func testCapacityPersistsAcrossInstancesAndIsIsolatedByStableDeviceUUID() throws {
        try withService { service, clock in
            XCTAssertTrue(service.updateNominalCapacityAh(72))
            service.setDeviceID(deviceB)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertTrue(service.updateNominalCapacityAh(48))
            service.setDeviceID(deviceA)
            XCTAssertEqual(service.nominalCapacityAh, 72)
            for invalid in [0.0, -1, .nan, .infinity] {
                XCTAssertFalse(service.updateNominalCapacityAh(invalid))
                XCTAssertEqual(service.nominalCapacityAh, 72)
            }
            let restored = RangeService(defaults: clock.defaults, clock: { clock.date })
            restored.setDeviceID(deviceA)
            XCTAssertEqual(restored.nominalCapacityAh, 72)
            service.reset()
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.setDeviceID(deviceB)
            XCTAssertEqual(service.nominalCapacityAh, 48)
        }
    }

    @MainActor
    func testMatchedMovingIntervalUsesPredictorAndWhPerKm() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let distance = service.accumulatedDistanceMeters
            XCTAssertEqual(service.status, .valid)
            XCTAssertEqual(service.validIntervalCount, 1)
            XCTAssertEqual(service.accumulatedNetWh, 1_000.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(distance, 22.238985, accuracy: 0.001)
            XCTAssertEqual(service.accumulatedNetAh, 15.0 / 3_600, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), distance * 3.6, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.referenceKmPerAh), (distance / 1_000) / (15.0 / 3_600), accuracy: 1e-9)
            let consumption = try XCTUnwrap(service.effectiveWhPerKm)
            XCTAssertEqual(consumption, service.accumulatedNetWh / (distance / 1_000), accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.prediction?.predictedRangeKm), try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 50, capacityAh: service.nominalCapacityAh)) / consumption, accuracy: 1e-9)
        }
    }

    @MainActor
    func testGPSWaitsForBMSCoverageAndDoesNotConsumeIntervalTwice() throws {
        try withService { service, clock in
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1)
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            XCTAssertNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.validIntervalCount, 0)
            service.ingest(snapshot: snapshot(clock.date))
            XCTAssertEqual(service.status, .valid)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            XCTAssertEqual(service.validIntervalCount, 1)
        }
    }

    @MainActor
    func testStationaryDischargeDoesNotEnterDrivingWindow() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0002, speed: 0))
            assertUnavailable(service, status: .noValidIntervals)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertEqual(service.accumulatedDistanceMeters, 0)
        }
    }

    @MainActor
    func testChargingAndGenericProtectionInvalidateWindowWithoutGuessingCellChemistry() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -100, status: 2))
            assertUnavailable(service, status: .charging)
            XCTAssertEqual(service.validIntervalCount, 0)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, status: 5))
            assertUnavailable(service, status: .noValidIntervals)
            XCTAssertTrue(service.reasonText.contains("保护"))
        }
    }

    @MainActor
    func testMissingNonFinitePowerAndMalformedFramesNeverFabricateEnergy() throws {
        for (power, length) in [(nil as Double?, 32), (Double.nan, 32), (Double.infinity, 32), (1_000, 0)] {
            try withService { service, clock in
                seedValidWindow(service, clock)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, power: power, frameLength: length))
                assertUnavailable(service, status: .noValidIntervals)
                XCTAssertEqual(service.accumulatedNetWh, 0)
            }
        }
    }

    @MainActor
    func testStalenessRemovesPreviouslyValidPredictionWithoutAnotherEvent() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(6)
            service.refresh()
            assertUnavailable(service, status: .telemetryStale)
            XCTAssertEqual(service.validIntervalCount, 0)
        }
    }

    @MainActor
    func testGPSStalenessIsDetectedEvenWhenBMSKeepsUpdating() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            for _ in 0..<11 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
            }
            assertUnavailable(service, status: .telemetryStale)
            XCTAssertTrue(service.reasonText.contains("GPS"))
        }
    }

    @MainActor
    func testInvalidFixBreaksPairingAndRejectsGPSJump() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(fix: fix(clock.date, longitude: .nan))
            assertUnavailable(service, status: .noValidIntervals)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.5))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 1))
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
        }
    }

    @MainActor
    func testBMSGapAndOutOfOrderEventsDoNotBridgeWindows() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            service.ingest(snapshot: snapshot(clock.date.addingTimeInterval(-1)))
            service.ingest(fix: fix(clock.date.addingTimeInterval(-1), longitude: -1))
            XCTAssertEqual(service.validIntervalCount, 1)
            clock.advance(6)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.001))
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
        }
    }

    @MainActor
    func testFutureTimestampsCannotPoisonNextRealSample() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            service.ingest(snapshot: snapshot(clock.date.addingTimeInterval(100)))
            service.ingest(fix: fix(clock.date.addingTimeInterval(100), longitude: 0.001))
            XCTAssertNil(service.prediction?.predictedRangeKm)
            seedValidWindow(service, clock)
            XCTAssertEqual(service.status, .valid)
        }
    }

    @MainActor
    func testDisconnectRequiresExplicitIdentityAgainAndCannotMixDevices() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            service.setConnectionReady(false)
            assertUnavailable(service, status: .disconnected)
            XCTAssertNil(service.deviceID)
            service.setConnectionReady(true)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.001))
            assertUnavailable(service, status: .disconnected)
            service.setDeviceID(deviceB)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.validIntervalCount, 0)
        }
    }

    @MainActor
    func testClearWindowPreservesCapacityButResetRemovesIt() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            XCTAssertTrue(service.updateNominalCapacityAh(72))
            XCTAssertNotNil(service.prediction)

            service.clearWindow()
            XCTAssertEqual(service.nominalCapacityAh, 72)
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertEqual(service.accumulatedDistanceMeters, 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertNil(service.prediction)
            XCTAssertNil(service.effectiveWhPerKm)

            service.reset()
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.validIntervalCount, 0)
        }
    }

    @MainActor
    func testLocationStopAndResetDiscardCachedSamples() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let oldTime = clock.date
            clock.advance(1)
            service.setLocationUpdating(false)
            assertUnavailable(service, status: .noValidIntervals)
            service.setLocationUpdating(true)
            service.ingest(snapshot: snapshot(oldTime))
            service.ingest(fix: fix(oldTime, longitude: 0.0002))
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            service.reset()
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertNil(service.prediction)
        }
    }

    @MainActor
    func testJSONAndCSVExportValidAndEmptyStateWithUniqueURLs() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let jsonURL = try service.exportJSONURL()
            let csvURL = try service.exportCSVURL()
            defer {
                try? FileManager.default.removeItem(at: jsonURL)
                try? FileManager.default.removeItem(at: csvURL)
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
            XCTAssertEqual(json["status"] as? String, "valid")
            XCTAssertEqual(json["deviceID"] as? String, deviceA.uuidString)
            XCTAssertNotNil(json["predictedRangeKm"])
            XCTAssertEqual(json["schemaVersion"] as? Int, 2)
            XCTAssertEqual(json["netAh"] as? Double, service.accumulatedNetAh)
            XCTAssertEqual(json["averageSpeedKmh"] as? Double, service.averageSpeedKmh)
            XCTAssertEqual(json["referenceKmPerAh"] as? Double, service.referenceKmPerAh)
            XCTAssertEqual(json["windowSeconds"] as? Double, service.windowAge)
            XCTAssertEqual(json["predictionRefreshSeconds"] as? Double, service.predictionRefreshInterval)
            XCTAssertEqual((json["intervals"] as? [[String: Any]])?.first?["netAh"] as? Double, service.accumulatedNetAh)
            XCTAssertEqual((json["intervals"] as? [[String: Any]])?.count, 1)
            XCTAssertNil(json["latitude"])
            let csv = try String(contentsOf: csvURL, encoding: .utf8)
            XCTAssertTrue(csv.contains("wh_per_km,predicted_range_km,status,reason"))
            XCTAssertTrue(csv.contains("\"valid\""))
            XCTAssertTrue(csv.contains("net_ah,average_speed_kmh,reference_km_per_ah,window_seconds,prediction_refresh_seconds"))
            let rows = csv.components(separatedBy: "\r\n")
            let values = rows[1].components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            XCTAssertEqual(values.count, 14)
            XCTAssertEqual(Double(values[9]), service.accumulatedNetAh)
            XCTAssertEqual(Double(values[10]), service.averageSpeedKmh)
            XCTAssertEqual(Double(values[11]), service.referenceKmPerAh)
            XCTAssertNotEqual(jsonURL.deletingPathExtension(), csvURL.deletingPathExtension())
            clock.advance(6)
            let emptyURL = try service.exportJSON()
            defer { try? FileManager.default.removeItem(at: emptyURL) }
            let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: emptyURL)) as? [String: Any])
            XCTAssertEqual(empty["status"] as? String, "telemetryStale")
            XCTAssertNil(empty["predictedRangeKm"])
            XCTAssertNil(empty["whPerKm"])
            XCTAssertNil(empty["averageSpeedKmh"])
            XCTAssertNil(empty["referenceKmPerAh"])
            XCTAssertEqual(empty["netAh"] as? Double, 0)
            XCTAssertEqual(empty["distanceMeters"] as? Double, 0)
        }
    }

    @MainActor
    func testPartialBMSTimeCoverageDoesNotBorrowUnrelatedEnergy() throws {
        try withService { service, clock in
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertEqual(service.accumulatedDistanceMeters, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
        }
    }

    @MainActor
    func testTrapezoidIntegrationClipsToGPSTimeBounds() throws {
        try withService { service, clock in
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            let start = clock.date
            service.ingest(snapshot: snapshot(start, power: 0, current: 0))
            clock.advance(0.5)
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1.5)
            service.ingest(snapshot: snapshot(clock.date, power: 2_000, current: 30))
            service.ingest(fix: fix(start.addingTimeInterval(1.5), longitude: 0.0002))
            XCTAssertEqual(service.status, .valid)
            // 功率 0→2000W/2s；GPS 仅覆盖 0.5→1.5s，平均功率 1000W，不能计入外侧能量。
            XCTAssertEqual(service.accumulatedNetWh, 1_000.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedNetAh, 15.0 / 3_600, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), service.accumulatedDistanceMeters * 3.6, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.referenceKmPerAh), (service.accumulatedDistanceMeters / 1_000) / (15.0 / 3_600), accuracy: 1e-9)
            XCTAssertEqual(service.validIntervalCount, 1)
        }
    }

    @MainActor
    func testCapacityMustBeConfiguredAndCannotBeLessThanMeasuredRemainingAh() throws {
        try withService { service, clock in
            service.ingest(snapshot: snapshot(clock.date))
            assertUnavailable(service, status: .capacityInvalid)
            XCTAssertTrue(service.updateNominalCapacityAh(10))
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            assertUnavailable(service, status: .capacityInvalid)
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            XCTAssertEqual(service.status, .valid)
        }
    }

    @MainActor
    func testGPSJumpCannotKeepAnOldValidPredictionVisible() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 1))
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            XCTAssertNil(service.effectiveWhPerKm)
        }
    }

    @MainActor
    func testWindowMetricsWeightOnlyMatchedIntervalsAndIntegrateRealCurrent() throws {
        try withService { service, clock in
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            service.ingest(snapshot: snapshot(clock.date, current: 6))
            service.ingest(fix: fix(clock.date, longitude: 0, speed: 1))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, current: 12))
            service.ingest(fix: fix(clock.date, longitude: 0.0002, speed: 2))
            clock.advance(2)
            service.ingest(snapshot: snapshot(clock.date, current: 30))
            service.ingest(fix: fix(clock.date, longitude: 0.0004, speed: 3))
            // 两段时长 1s/2s，真实电流梯形积分为 9 + 42 A*s，不使用功率/66V。
            let ah = 51.0 / 3_600
            XCTAssertEqual(service.validIntervalCount, 2)
            XCTAssertEqual(service.accumulatedNetAh, ah, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), service.accumulatedDistanceMeters / 3 * 3.6, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.referenceKmPerAh), (service.accumulatedDistanceMeters / 1_000) / ah, accuracy: 1e-9)
        }
    }

    @MainActor
    func testZeroMeasuredCurrentDoesNotInventAhFromPowerOrCapacity() throws {
        try withService { service, clock in
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            service.ingest(snapshot: snapshot(clock.date, current: 0))
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, current: 0))
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            XCTAssertEqual(service.status, .valid)
            XCTAssertEqual(service.accumulatedNetAh, 0)
            XCTAssertNotNil(service.averageSpeedKmh)
            XCTAssertNil(service.referenceKmPerAh)
        }
    }

    @MainActor
    func testInvalidCurrentClearsAllWindowMetricsWithoutFabricatingAh() throws {
        for current in [Double.nan, .infinity, -1] {
            try withService { service, clock in
                seedValidWindow(service, clock)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, current: current))
                assertUnavailable(service, status: current < 0 ? .charging : .noValidIntervals)
                XCTAssertEqual(service.accumulatedNetAh, 0)
                XCTAssertEqual(service.validIntervalCount, 0)
            }
        }
    }

    @MainActor
    func testWindowSettingsNormalizeRetainLongWindowAndPruneWithoutResurrectingData() throws {
        try withService { service, clock in
            var settings = DrivingSettings.defaults
            settings.rangeWindowMinutes = 999
            settings.rangeRefreshSeconds = -1
            service.applyDrivingSettings(settings)
            XCTAssertEqual(service.windowAge, 3_600)
            XCTAssertEqual(service.predictionRefreshInterval, 10)
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0))
            for index in 1...400 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: Double(index) * 0.0002))
            }
            XCTAssertEqual(service.validIntervalCount, 400) // 不能被旧 256 段上限截断。
            settings.rangeWindowMinutes = 3
            settings.rangeRefreshSeconds = 60
            service.applyDrivingSettings(settings)
            // 按区间结束时间保留，恰好位于窗口左边界的完整区间也保留。
            XCTAssertEqual(service.validIntervalCount, 181)
            XCTAssertEqual(service.accumulatedNetAh, 181 * 15.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedNetWh, 181 * 1_000.0 / 3_600, accuracy: 1e-9)
            let retainedDistance = service.accumulatedDistanceMeters
            XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), retainedDistance / 181 * 3.6, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.referenceKmPerAh), (retainedDistance / 1_000) / service.accumulatedNetAh, accuracy: 1e-9)
            settings.rangeWindowMinutes = 60
            service.applyDrivingSettings(settings)
            XCTAssertEqual(service.validIntervalCount, 181)
            XCTAssertEqual(service.accumulatedDistanceMeters, retainedDistance)
            XCTAssertEqual(service.nominalCapacityAh, 100)
        }
    }

    @MainActor
    func testPredictionCadenceDoesNotThrottleWindowMetricsAndSettingsRecomputeImmediately() throws {
        try withService { service, clock in
            var settings = DrivingSettings.defaults
            settings.rangeRefreshSeconds = 60
            service.applyDrivingSettings(settings)
            seedValidWindow(service, clock)
            let initial = try XCTUnwrap(service.prediction?.predictedRangeKm)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: 3_000, current: 45))
            service.ingest(fix: fix(clock.date, longitude: 0.0004))
            XCTAssertEqual(service.prediction?.predictedRangeKm, initial)
            XCTAssertEqual(service.accumulatedNetAh, 45.0 / 3_600, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(service.effectiveWhPerKm), service.accumulatedNetWh / (service.accumulatedDistanceMeters / 1_000), accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.referenceKmPerAh), (service.accumulatedDistanceMeters / 1_000) / service.accumulatedNetAh, accuracy: 1e-9)
            service.applyDrivingSettings(settings) // 同配置不绕过节流。
            XCTAssertEqual(service.prediction?.predictedRangeKm, initial)
            settings.rangeRefreshSeconds = 10
            service.applyDrivingSettings(settings)
            XCTAssertLessThan(try XCTUnwrap(service.prediction?.predictedRangeKm), initial)
            let updated = service.prediction?.predictedRangeKm
            for index in 3...11 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, power: 3_000, current: 45))
                service.ingest(fix: fix(clock.date, longitude: Double(index) * 0.0002))
            }
            XCTAssertEqual(service.prediction?.predictedRangeKm, updated)
            clock.advance(1) // 距离配置变更已满 10 秒。
            service.ingest(snapshot: snapshot(clock.date, power: 3_000, current: 45))
            service.ingest(fix: fix(clock.date, longitude: 0.0024))
            XCTAssertLessThan(try XCTUnwrap(service.prediction?.predictedRangeKm), try XCTUnwrap(updated))
        }
    }

    @MainActor
    func testSafetyStatesBypassLongestPredictionCadence() throws {
        for scenario in 0..<7 {
            try withService { service, clock in
                var settings = DrivingSettings.defaults
                settings.rangeRefreshSeconds = 60
                service.applyDrivingSettings(settings)
                seedValidWindow(service, clock)
                switch scenario {
                case 0:
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, power: -100, status: 2, current: -2))
                    assertUnavailable(service, status: .charging)
                case 1:
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, status: 5))
                    assertUnavailable(service, status: .noValidIntervals)
                case 2:
                    clock.advance(6)
                    service.refresh()
                    assertUnavailable(service, status: .telemetryStale)
                case 3:
                    service.setConnectionReady(false)
                    assertUnavailable(service, status: .disconnected)
                case 4:
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, remainingAh: 101))
                    assertUnavailable(service, status: .capacityInvalid)
                case 5:
                    for _ in 0..<11 {
                        clock.advance(1)
                        service.ingest(snapshot: snapshot(clock.date))
                    }
                    assertUnavailable(service, status: .telemetryStale)
                default:
                    clock.advance(1)
                    service.ingest(fix: fix(clock.date, longitude: 0.0002, speed: 0))
                    assertUnavailable(service, status: .noValidIntervals)
                }
            }
        }
    }

    @MainActor
    func testClearAndResetPreserveConfigurationOtherDevicesAndExportedFile() throws {
        try withService { service, clock in
            service.setDeviceID(deviceB)
            XCTAssertTrue(service.updateNominalCapacityAh(48))
            service.setDeviceID(deviceA)
            var settings = DrivingSettings.defaults
            settings.rangeWindowMinutes = 30
            settings.rangeRefreshSeconds = 60
            service.applyDrivingSettings(settings)
            seedValidWindow(service, clock)
            let url = try service.exportJSON()
            defer { try? FileManager.default.removeItem(at: url) }
            service.clearWindow()
            XCTAssertEqual(service.accumulatedNetAh, 0)
            XCTAssertNil(service.averageSpeedKmh)
            XCTAssertNil(service.referenceKmPerAh)
            XCTAssertNil(service.lastExportURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(service.nominalCapacityAh, 100)
            XCTAssertEqual(service.windowAge, 1_800)
            XCTAssertEqual(service.predictionRefreshInterval, 60)
            service.reset()
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.windowAge, 1_800)
            XCTAssertEqual(service.predictionRefreshInterval, 60)
            service.setDeviceID(deviceB)
            XCTAssertEqual(service.nominalCapacityAh, 48)
            XCTAssertEqual(service.accumulatedNetAh, 0)
        }
    }

    @MainActor
    func testExportFailurePublishesErrorAndDoesNotSharePreviousSuccess() throws {
        try withService { _, clock in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = RangeService(defaults: clock.defaults, clock: { clock.date }, exportDirectory: directory)
            let url = try service.exportJSON()
            XCTAssertEqual(service.lastExportURL, url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.removeItem(at: directory)
            try Data("not a directory".utf8).write(to: directory)
            XCTAssertThrowsError(try service.exportCSV())
            XCTAssertNil(service.lastExportURL)
            XCTAssertTrue(try XCTUnwrap(service.lastError).contains("导出失败"))
            XCTAssertThrowsError(try service.exportJSON())
            XCTAssertNil(service.lastExportURL)
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let recovered = try service.exportCSV()
            defer { try? FileManager.default.removeItem(at: recovered) }
            XCTAssertEqual(service.lastExportURL, recovered)
            XCTAssertNil(service.lastError)
        }
    }

    // MARK: - 无蓝牙/定位硬件依赖的可控事件夹具
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    }

    @MainActor
    private func withService(_ test: (RangeService, Clock) throws -> Void) throws {
        let suite = "RangeServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock(defaults: defaults)
        let service = RangeService(defaults: defaults, clock: { clock.date })
        service.setConnectionReady(true)
        service.setLocationUpdating(true)
        service.setDeviceID(deviceA)
        try test(service, clock)
    }

    @MainActor
    private func seedValidWindow(_ service: RangeService, _ clock: Clock) {
        XCTAssertTrue(service.updateNominalCapacityAh(100))
        service.ingest(snapshot: snapshot(clock.date))
        service.ingest(fix: fix(clock.date, longitude: 0))
        clock.advance(1)
        service.ingest(snapshot: snapshot(clock.date))
        service.ingest(fix: fix(clock.date, longitude: 0.0002))
    }

    @MainActor
    private func assertUnavailable(_ service: RangeService, status: RangePredictionStatus,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.status, status, file: file, line: line)
        XCTAssertNil(service.prediction?.predictedRangeKm, file: file, line: line)
        XCTAssertNil(service.effectiveWhPerKm, file: file, line: line)
        XCTAssertNil(service.averageSpeedKmh, file: file, line: line)
        XCTAssertNil(service.referenceKmPerAh, file: file, line: line)
        XCTAssertFalse(service.reasonText.isEmpty, file: file, line: line)
    }

    private func snapshot(_ date: Date, power: Double? = 1_000, status: Int = 3,
                          frameLength: Int = 32, current: Double = 15, remainingAh: Double = 50) -> BmsSnapshot {
        BmsSnapshot(receivedAt: date, totalVoltage: 66, current: current, soc: 50,
                    capacityAh: 100, remainingAh: remainingAh, temperatures: [], mosTemperature: 0,
                    balancerTemperature: 0, cellVoltagesMillivolts: [3_300], power: power,
                    statusCode: status, frameLength: frameLength)
    }
    private func fix(_ date: Date, longitude: Double, speed: Double = 22) -> GpsFix {
        GpsFix(timestamp: date, latitude: 0, longitude: longitude, speed: speed, horizontalAccuracy: 5)
    }
}
