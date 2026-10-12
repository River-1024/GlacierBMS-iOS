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
        }
    }

    @MainActor
    func testLegacyCapacityDefaultsAreIgnoredAcrossDevicesAndColdStart() throws {
        try withService { service, clock in
            let keyA = "com.zjsf.anturide.range.capacity.\(deviceA.uuidString)"
            let keyB = "com.zjsf.anturide.range.capacity.\(deviceB.uuidString)"
            clock.defaults.set(72.0, forKey: keyA)
            clock.defaults.set(48.0, forKey: keyB)
            service.setDeviceID(deviceB)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(clock.date, remainingAh: 24, capacityAh: 80))
            XCTAssertEqual(service.nominalCapacityAh, 80)
            service.setDeviceID(deviceA)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(clock.date, capacityAh: 134))
            XCTAssertEqual(service.nominalCapacityAh, 134)

            let restored = RangeService(defaults: clock.defaults, clock: { clock.date })
            restored.setConnectionReady(true)
            restored.setLocationUpdating(true)
            restored.setDeviceID(deviceA)
            XCTAssertEqual(restored.nominalCapacityAh, 0)
            restored.ingest(snapshot: snapshot(clock.date))
            XCTAssertEqual(restored.nominalCapacityAh, 100)
            XCTAssertEqual(clock.defaults.double(forKey: keyA), 72)
            XCTAssertEqual(clock.defaults.double(forKey: keyB), 48)
        }
    }

    @MainActor
    func testLegacyCapacityCannotSelectPredictionCurve() throws {
        for legacy in [72.0, 134, 10_001] {
            try withService { service, clock in
                let key = "com.zjsf.anturide.range.capacity.\(deviceA.uuidString)"
                clock.defaults.set(legacy, forKey: key)
                service.setDeviceID(nil)
                service.setDeviceID(deviceA)
                XCTAssertEqual(service.nominalCapacityAh, 0)
                seedValidWindow(service, clock)
                let consumption = try XCTUnwrap(service.effectiveWhPerKm)
                let energy = try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 50, capacityAh: 100))
                XCTAssertEqual(service.nominalCapacityAh, 100)
                XCTAssertEqual(try XCTUnwrap(service.prediction?.predictedRangeKm), energy / consumption, accuracy: 1e-9)
                XCTAssertEqual(clock.defaults.double(forKey: key), legacy)
            }
        }
    }

    @MainActor
    func testAutomatic134AhCapacityUsesSeedPrediction() throws {
        try withService { service, clock in
            seedValidWindow(service, clock, capacityAh: 134)
            let consumption = try XCTUnwrap(service.effectiveWhPerKm)
            let seedEnergy = try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 50, capacityAh: 134))
            let x = 50.0 / 134
            let legacyEnergy = 50 * (66 + 9.8679 * x - 7.7636 * x * x + 5.8888 * x * x * x)
            XCTAssertNotEqual(seedEnergy, legacyEnergy, accuracy: 1e-6)
            XCTAssertEqual(service.nominalCapacityAh, 134)
            XCTAssertEqual(try XCTUnwrap(service.prediction?.predictedRangeKm), seedEnergy / consumption, accuracy: 1e-9)
        }
    }

    @MainActor
    func testOtherAutomaticCapacitiesUseUnscaledLegacyPrediction() throws {
        for capacity in [48.0, 72, 100, 200] {
            try withService { service, clock in
                let remaining = capacity / 2
                seedValidWindow(service, clock, capacityAh: capacity, remainingAh: remaining)
                let x = remaining / capacity
                let energy = remaining * (66 + 9.8679 * x - 7.7636 * x * x + 5.8888 * x * x * x)
                let consumption = try XCTUnwrap(service.effectiveWhPerKm)
                XCTAssertEqual(service.nominalCapacityAh, capacity)
                XCTAssertEqual(try XCTUnwrap(service.prediction?.predictedRangeKm), energy / consumption, accuracy: 1e-9)
            }
        }
    }

    @MainActor
    func testInvalidBMSCapacityWithdrawsLiveCapacityAndBreaksPairingWithoutDeletingHistory() throws {
        for capacity in [0.0, -1, .nan, .infinity, -.infinity, 10_000.000001] {
            try withService { service, clock in
                seedValidWindow(service, clock)
                let wh = service.accumulatedNetWh
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, capacityAh: capacity))
                service.ingest(fix: fix(clock.date, longitude: 0.0062))
                assertUnavailable(service, status: .capacityInvalid)
                XCTAssertEqual(service.nominalCapacityAh, 0)
                XCTAssertEqual(service.validIntervalCount, 30)
                XCTAssertEqual(service.accumulatedNetWh, wh)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: 0.0064))
                XCTAssertEqual(service.nominalCapacityAh, 100)
                XCTAssertEqual(service.validIntervalCount, 30)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: 0.0066))
                XCTAssertEqual(service.validIntervalCount, 31)
                XCTAssertEqual(service.accumulatedNetWh, wh + 990.0 / 3_600, accuracy: 1e-9)
            }
        }
    }

    @MainActor
    func testRemainingAhMustBeFiniteAndWithinCurrentSnapshotCapacity() throws {
        for remaining in [-0.000001, Double.nan, .infinity, -.infinity, 100.000001] {
            try withService { service, clock in
                seedValidWindow(service, clock)
                let wh = service.accumulatedNetWh
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, remainingAh: remaining))
                service.ingest(fix: fix(clock.date, longitude: 0.0062))
                assertUnavailable(service, status: .capacityInvalid)
                XCTAssertEqual(service.nominalCapacityAh, 0)
                XCTAssertEqual(service.validIntervalCount, 30)
                XCTAssertEqual(service.accumulatedNetWh, wh)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: 0.0064))
                XCTAssertEqual(service.nominalCapacityAh, 100)
                XCTAssertEqual(service.validIntervalCount, 30)
            }
        }
    }

    @MainActor
    func testCapacityUpperBoundAndRemainingAhEndpointsAreAccepted() throws {
        for (capacity, remaining) in [(0.000001, 0.0), (100.0, 0.0), (100.0, 100.0),
                                      (10_000.0, 0.0), (10_000.0, 10_000.0)] {
            try withService { service, clock in
                service.ingest(snapshot: snapshot(clock.date, remainingAh: remaining, capacityAh: capacity))
                XCTAssertEqual(service.nominalCapacityAh, capacity)
                assertUnavailable(service, status: .accumulating) // Capacity is valid; GPS is missing.
                XCTAssertEqual(service.validIntervalCount, 0)
            }
        }
    }

    @MainActor
    func testEveryExactCapacityChangeClearsWindowAndGPSEndpointBeforeRebuild() throws {
        // Curve selection has a tolerance; evidence identity must not reuse that tolerance.
        for capacity in [134.0, 100.0000005] {
            try withService { service, clock in
                var settings = DrivingSettings.defaults
                settings.rangeRefreshSeconds = 60
                service.applyDrivingSettings(settings)
                seedValidWindow(service, clock)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, capacityAh: capacity))
                XCTAssertEqual(service.nominalCapacityAh, capacity)
                XCTAssertEqual(service.validIntervalCount, 0)
                XCTAssertEqual(service.effectiveDuration, 0)
                XCTAssertEqual(service.accumulatedDistanceMeters, 0)
                XCTAssertEqual(service.accumulatedNetWh, 0)
                XCTAssertEqual(service.accumulatedNetAh, 0)
                XCTAssertNil(service.prediction)
                XCTAssertNil(service.effectiveWhPerKm)
                service.ingest(fix: fix(clock.date, longitude: 0.0062))
                XCTAssertEqual(service.validIntervalCount, 0) // Cannot join to the old GPS endpoint.
                for second in 1...30 {
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, capacityAh: capacity))
                    service.ingest(fix: fix(clock.date, longitude: 0.0062 + Double(second) * 0.0002))
                }
                XCTAssertEqual(service.validIntervalCount, 30)
                XCTAssertEqual(service.accumulatedNetWh, 8.25, accuracy: 1e-9)
                // Rebuild is real evidence; cadence may still be holding the first empty cache.
                settings.rangeRefreshSeconds = 10
                service.applyDrivingSettings(settings)
                XCTAssertEqual(service.status, .valid)
            }
        }
    }

    @MainActor
    func testCapacityChangeAfterInvalidSnapshotStillRejectsOldEvidence() throws {
        try withService { service, clock in
            seedValidWindow(service, clock, capacityAh: 134)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, capacityAh: 0))
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.validIntervalCount, 30)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            XCTAssertEqual(service.nominalCapacityAh, 100)
            XCTAssertEqual(service.validIntervalCount, 0)
            service.ingest(fix: fix(clock.date, longitude: 0.0064))
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertNil(service.prediction)
        }
    }

    @MainActor
    func testStoredWindowV2IncludesEvidenceCapacityButNeverRestoresLiveCapacity() throws {
        try withService { service, clock in
            seedValidWindow(service, clock, capacityAh: 134)
            service.setConnectionReady(false) // Flush the complete, device-isolated window.
            let key = "com.zjsf.anturide.range.driving.\(deviceA.uuidString)"
            let data = try XCTUnwrap(clock.defaults.data(forKey: key))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let version = try XCTUnwrap(object["version"] as? String)
            XCTAssertEqual(version, "android-driving-window-v2-bms-capacity")
            XCTAssertEqual(try XCTUnwrap(object["capacityAh"] as? Double), 134)
            XCTAssertEqual(object["deviceID"] as? String, deviceA.uuidString)
            XCTAssertEqual(try XCTUnwrap(object["intervals"] as? [[String: Any]]).count, 30)
            XCTAssertNil(clock.defaults.object(forKey: "com.zjsf.anturide.range.capacity.\(deviceA.uuidString)"))

            let restored = RangeService(defaults: clock.defaults, clock: { clock.date })
            restored.setConnectionReady(true)
            restored.setLocationUpdating(true)
            restored.setDeviceID(deviceA)
            XCTAssertEqual(restored.validIntervalCount, 30)
            XCTAssertEqual(restored.nominalCapacityAh, 0)
            XCTAssertNil(restored.prediction)
            restored.refresh()
            XCTAssertEqual(restored.nominalCapacityAh, 0)
        }
    }

    @MainActor
    func testFirstValidSnapshotChecksEvidenceCapacityOnReconnectAndColdStart() throws {
        for coldStart in [false, true] {
            for capacity in [100.0, 134, 100.0000005] {
                try withService { service, clock in
                    seedValidWindow(service, clock)
                    let wh = service.accumulatedNetWh
                    service.setConnectionReady(false)
                    clock.advance(60)
                    let restored = coldStart
                        ? RangeService(defaults: clock.defaults, clock: { clock.date }) : service
                    restored.setConnectionReady(true)
                    restored.setLocationUpdating(true)
                    restored.setDeviceID(deviceA)
                    XCTAssertEqual(restored.nominalCapacityAh, 0)
                    XCTAssertEqual(restored.validIntervalCount, 30)
                    XCTAssertNil(restored.prediction)
                    restored.ingest(snapshot: snapshot(clock.date, capacityAh: 0))
                    XCTAssertEqual(restored.nominalCapacityAh, 0)
                    XCTAssertEqual(restored.validIntervalCount, 30) // Not the first valid BMS yet.
                    clock.advance(1)
                    restored.ingest(snapshot: snapshot(clock.date, capacityAh: capacity))
                    XCTAssertEqual(restored.nominalCapacityAh, capacity)
                    let expectedCount = capacity == 100 ? 30 : 0
                    XCTAssertEqual(restored.validIntervalCount, expectedCount)
                    XCTAssertEqual(restored.accumulatedNetWh, capacity == 100 ? wh : 0)
                    restored.ingest(fix: fix(clock.date, longitude: 0.0062))
                    XCTAssertEqual(restored.validIntervalCount, expectedCount)
                    clock.advance(1)
                    restored.ingest(snapshot: snapshot(clock.date, capacityAh: capacity))
                    restored.ingest(fix: fix(clock.date, longitude: 0.0064))
                    XCTAssertEqual(restored.validIntervalCount, expectedCount + 1)
                }
            }
        }
    }

    @MainActor
    func testLegacyWindowWithoutCapacityMetadataCannotBeTrusted() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            service.setConnectionReady(false)
            let key = "com.zjsf.anturide.range.driving.\(deviceA.uuidString)"
            let data = try XCTUnwrap(clock.defaults.data(forKey: key))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["version"] = "android-driving-window-v1-seed-only"
            object.removeValue(forKey: "capacityAh")
            clock.defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
            let restored = RangeService(defaults: clock.defaults, clock: { clock.date })
            restored.setConnectionReady(true)
            restored.setLocationUpdating(true)
            restored.setDeviceID(deviceA)
            XCTAssertEqual(restored.nominalCapacityAh, 0)
            XCTAssertEqual(restored.validIntervalCount, 0)
            restored.ingest(snapshot: snapshot(clock.date))
            restored.ingest(fix: fix(clock.date, longitude: 0.006))
            XCTAssertEqual(restored.nominalCapacityAh, 100)
            XCTAssertEqual(restored.validIntervalCount, 0)
            XCTAssertNil(restored.prediction)
        }
    }

    @MainActor
    func testV2WindowRequiresValidCapacityMetadataAndMatchingDeviceIdentity() throws {
        for scenario in 0..<5 {
            try withService { service, clock in
                seedValidWindow(service, clock)
                service.setConnectionReady(false)
                let key = "com.zjsf.anturide.range.driving.\(deviceA.uuidString)"
                let data = try XCTUnwrap(clock.defaults.data(forKey: key))
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(object["version"] as? String, "android-driving-window-v2-bms-capacity")
                switch scenario {
                case 0: object.removeValue(forKey: "capacityAh")
                case 1: object["capacityAh"] = 0.0
                case 2: object["capacityAh"] = 10_001.0
                case 3: object["capacityAh"] = "100"
                default: object["deviceID"] = deviceB.uuidString
                }
                clock.defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
                let restored = RangeService(defaults: clock.defaults, clock: { clock.date })
                restored.setConnectionReady(true)
                restored.setLocationUpdating(true)
                restored.setDeviceID(deviceA)
                XCTAssertEqual(restored.nominalCapacityAh, 0)
                XCTAssertEqual(restored.validIntervalCount, 0)
                restored.ingest(snapshot: snapshot(clock.date))
                restored.ingest(fix: fix(clock.date, longitude: 0.006))
                XCTAssertEqual(restored.nominalCapacityAh, 100)
                XCTAssertEqual(restored.validIntervalCount, 0)
                XCTAssertNil(restored.prediction)
            }
        }
    }

    @MainActor
    func testLiveCapacityExpiresAtBMSFreshnessBoundaryAndNeedsNewValidTelemetry() throws {
        try withService { service, clock in
            service.ingest(snapshot: snapshot(clock.date, capacityAh: 134))
            let oldTime = clock.date
            XCTAssertEqual(service.nominalCapacityAh, 134)
            clock.advance(30)
            service.refresh()
            XCTAssertEqual(service.nominalCapacityAh, 134)
            clock.advance(0.000001)
            service.refresh()
            assertUnavailable(service, status: .telemetryStale)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(oldTime, capacityAh: 134))
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(clock.date))
            XCTAssertEqual(service.nominalCapacityAh, 100)
            XCTAssertNil(service.prediction) // New BMS alone is not new GPS evidence.
        }
    }

    @MainActor
    func testSamplingRestartWithdrawsCapacityUntilNewBMSWithoutErasingEvidence() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            let oldTime = clock.date
            clock.advance(1)
            service.setLocationUpdating(false)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            service.setLocationUpdating(true)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(oldTime))
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(clock.date, capacityAh: 134))
            XCTAssertEqual(service.nominalCapacityAh, 134)
            XCTAssertEqual(service.validIntervalCount, 0) // Restart must retain capacity identity, not just live data.
            XCTAssertNil(service.prediction)
        }
    }

    @MainActor
    func testMatchedMovingIntervalUsesPredictorAndWhPerKm() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let distance = service.accumulatedDistanceMeters
            XCTAssertEqual(service.status, .valid)
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.effectiveDuration, 30)
            // Reported 1000W is not the source: measured 66V * 15A = 990W.
            XCTAssertEqual(service.accumulatedNetWh, 990 * 30.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedDischargeWh, service.accumulatedNetWh, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedRegenerationWh, 0)
            XCTAssertEqual(distance, 22.238985 * 30, accuracy: 0.001)
            XCTAssertEqual(service.accumulatedNetAh, 0) // Remaining Ah is unchanged, despite nonzero current.
            XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), distance / 30 * 3.6, accuracy: 1e-9)
            XCTAssertNil(service.referenceKmPerAh)
            let consumption = try XCTUnwrap(service.effectiveWhPerKm)
            XCTAssertEqual(consumption, service.accumulatedNetWh / (distance / 1_000), accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.prediction?.predictedRangeKm), try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 50, capacityAh: 100)) / consumption, accuracy: 1e-9)
        }
    }

    @MainActor
    func testGPSUsesTenSecondOldBMSWithoutWaitingBackfillingOrDuplicating() throws {
        try withService { service, clock in
            var settings = DrivingSettings.defaults
            settings.bluetoothRefreshIntervalMs = 5_000
            service.applyDrivingSettings(settings) // 2x query cadence, capped at Android's 10s maximum.
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(10)
            service.ingest(fix: fix(clock.date, longitude: 0.002))
            XCTAssertEqual(service.validIntervalCount, 1) // Age exactly 10s is permitted.
            XCTAssertEqual(service.accumulatedNetWh, 990 * 10.0 / 3_600, accuracy: 1e-9)
            service.ingest(snapshot: snapshot(clock.date, current: 30))
            service.ingest(fix: fix(clock.date, longitude: 0.002))
            XCTAssertEqual(service.validIntervalCount, 1)
            XCTAssertEqual(service.accumulatedNetWh, 990 * 10.0 / 3_600, accuracy: 1e-9)
            clock.advance(1)
            service.ingest(fix: fix(clock.date, longitude: 0.0022))
            XCTAssertEqual(service.validIntervalCount, 2)
            XCTAssertEqual(service.accumulatedNetWh, (990 * 10.0 + 1_485) / 3_600, accuracy: 1e-9)
            XCTAssertNil(service.prediction?.predictedRangeKm) // Only 11s, not yet 30s.
        }
    }

    @MainActor
    func testStationaryDischargePreservesHistoryButDoesNotRenewDrivingEvidence() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            for _ in 0..<31 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
            }
            XCTAssertNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.effectiveDuration, 30)
            XCTAssertEqual(service.accumulatedNetWh, wh)
        }
    }

    @MainActor
    func testStationaryChargingAndProtectionWithdrawPredictionButPreserveHistory() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2))
            service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2))
            service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
            assertUnavailable(service, status: .charging)
            XCTAssertEqual(service.validIntervalCount, 30)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, status: 5))
            assertUnavailable(service, status: .noValidIntervals)
            XCTAssertTrue(service.reasonText.contains("保护"))
            XCTAssertEqual(service.accumulatedNetWh, wh)
        }
    }

    @MainActor
    func testInvalidElectricalValuesAndMalformedFramesExcludeBadSegmentsWithoutDeletingHistory() throws {
        for (current, voltage, length) in [(Double.nan, 66.0, 32), (Double.infinity, 66.0, 32),
                                          (15.0, Double.nan, 32), (15.0, Double.infinity, 32), (15.0, 66.0, 0)] {
            try withService { service, clock in
                seedValidWindow(service, clock)
                let wh = service.accumulatedNetWh
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, power: nil, frameLength: length, current: current, voltage: voltage))
                service.ingest(fix: fix(clock.date, longitude: 0.0062))
                XCTAssertNil(service.prediction?.predictedRangeKm)
                XCTAssertEqual(service.nominalCapacityAh, 0)
                XCTAssertEqual(service.accumulatedNetWh, wh)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: 0.0064))
                XCTAssertEqual(service.validIntervalCount, 30)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: 0.0066))
                XCTAssertEqual(service.validIntervalCount, 31)
                XCTAssertEqual(service.accumulatedNetWh, wh + 990.0 / 3_600, accuracy: 1e-9)
            }
        }
    }

    @MainActor
    func testStalenessWithdrawsPredictionWithoutWallClockEvictingHistory() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(3_600)
            service.refresh()
            assertUnavailable(service, status: .telemetryStale)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.effectiveDuration, 30)
            XCTAssertEqual(service.accumulatedNetWh, 8.25, accuracy: 1e-9)
        }
    }

    @MainActor
    func testGPSStalenessIsDetectedEvenWhenBMSKeepsUpdating() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            for _ in 0..<31 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date))
            }
            assertUnavailable(service, status: .telemetryStale)
            XCTAssertEqual(service.nominalCapacityAh, 100) // BMS is fresh even though GPS is stale.
            XCTAssertEqual(service.validIntervalCount, 30)
        }
    }

    @MainActor
    func testInvalidFixBreaksPairingAndRejectsGPSJumpWithoutDeletingHistory() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            clock.advance(1)
            service.ingest(fix: fix(clock.date, longitude: .nan))
            XCTAssertNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.5))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 1))
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            XCTAssertNotNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.status, .valid)
        }
    }

    @MainActor
    func testBMSGapOverTenSecondsAndOutOfOrderEventsDoNotBridgeHistory() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            // Exact duplicate events are ignored; a lower timestamp is a new epoch and tested separately.
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.006))
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            clock.advance(11)
            service.ingest(fix: fix(clock.date, longitude: 0.0082)) // Reject BMS older than 10s.
            service.ingest(snapshot: snapshot(clock.date)) // Cannot backfill rejected GPS.
            XCTAssertEqual(service.validIntervalCount, 30)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0084))
            XCTAssertEqual(service.validIntervalCount, 30)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0086))
            XCTAssertEqual(service.validIntervalCount, 31)
            XCTAssertEqual(service.accumulatedNetWh, wh + 990.0 / 3_600, accuracy: 1e-9)
        }
    }

    @MainActor
    func testFutureTimestampsCannotPoisonNextRealSample() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            service.ingest(snapshot: snapshot(clock.date.addingTimeInterval(100), remainingAh: 1))
            service.ingest(fix: fix(clock.date.addingTimeInterval(100), longitude: 1))
            XCTAssertEqual(service.accumulatedNetWh, wh)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0062))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0064))
            XCTAssertEqual(service.status, .valid)
            XCTAssertGreaterThan(service.effectiveDuration, 30)
        }
    }

    @MainActor
    func testDisconnectRequiresIdentityAndRestoresOnlyMatchingUUIDWithoutBridgingGap() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            service.setConnectionReady(false)
            assertUnavailable(service, status: .disconnected)
            XCTAssertNil(service.deviceID)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.setConnectionReady(true)
            clock.advance(60)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.05))
            assertUnavailable(service, status: .disconnected)
            service.setDeviceID(deviceB)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.validIntervalCount, 0)
            service.setDeviceID(deviceA)
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            service.ingest(snapshot: snapshot(clock.date))
            XCTAssertEqual(service.nominalCapacityAh, 100)
            service.ingest(fix: fix(clock.date, longitude: 0.05))
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0502))
            XCTAssertEqual(service.validIntervalCount, 31)
            XCTAssertEqual(service.status, .valid)
        }
    }

    @MainActor
    func testClearWindowAndResetRequireNewBMSAndGPSEndpoints() throws {
        for reset in [false, true] {
            try withService { service, clock in
                seedValidWindow(service, clock, capacityAh: 72)
                let oldTime = clock.date
                clock.advance(1)
                if reset { service.reset() } else { service.clearWindow() }
                XCTAssertEqual(service.nominalCapacityAh, 0)
                XCTAssertEqual(service.validIntervalCount, 0)
                XCTAssertEqual(service.accumulatedDistanceMeters, 0)
                XCTAssertEqual(service.accumulatedNetWh, 0)
                XCTAssertNil(service.prediction)
                XCTAssertNil(service.effectiveWhPerKm)
                service.refresh()
                XCTAssertEqual(service.nominalCapacityAh, 0)

                service.ingest(snapshot: snapshot(oldTime, capacityAh: 72))
                service.ingest(fix: fix(oldTime, longitude: 0.006))
                XCTAssertEqual(service.nominalCapacityAh, 0)
                service.ingest(fix: fix(clock.date, longitude: 0.0062))
                XCTAssertEqual(service.validIntervalCount, 0)
                XCTAssertEqual(service.nominalCapacityAh, 0)
                service.ingest(snapshot: snapshot(clock.date, capacityAh: 72))
                XCTAssertEqual(service.nominalCapacityAh, 72)
                XCTAssertEqual(service.validIntervalCount, 0)
                XCTAssertNil(service.prediction)
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, capacityAh: 72))
                service.ingest(fix: fix(clock.date, longitude: 0.0064))
                XCTAssertEqual(service.validIntervalCount, 0) // First paired endpoint, not a bridge.
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, capacityAh: 72))
                service.ingest(fix: fix(clock.date, longitude: 0.0066))
                XCTAssertEqual(service.validIntervalCount, 1)
                XCTAssertEqual(service.accumulatedNetWh, 990.0 / 3_600, accuracy: 1e-9)
            }
        }
    }

    @MainActor
    func testLocationStopRetainsHistoryButDiscardsCachedPairingEndpoints() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let oldTime = clock.date
            let wh = service.accumulatedNetWh
            clock.advance(60)
            service.setLocationUpdating(false)
            assertUnavailable(service, status: .noValidIntervals)
            service.setLocationUpdating(true)
            service.ingest(snapshot: snapshot(oldTime))
            service.ingest(fix: fix(oldTime, longitude: 0.006))
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.05))
            XCTAssertEqual(service.accumulatedNetWh, wh)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0502))
            XCTAssertEqual(service.validIntervalCount, 31)
            XCTAssertEqual(service.status, .valid)
            service.reset()
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.effectiveDuration, 0)
            XCTAssertNil(service.prediction)
        }
    }

    @MainActor
    func testJSONSchemaFourAndCSVExportPreserveFieldsAndStaleHistory() throws {
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
            XCTAssertEqual(json["schemaVersion"] as? Int, 4)
            XCTAssertEqual(json["capacitySource"] as? String, "fresh BMS capacityAh; manual preferences ignored")
            XCTAssertEqual(json["nominalCapacityAh"] as? Double, 100)
            for key in ["energyDataVersion", "model", "generatedAt", "nominalCapacityAh", "reason",
                        "whPerKm", "distanceMeters", "netWh", "windowSeconds", "predictionRefreshSeconds"] {
                XCTAssertNotNil(json[key], "Missing legacy export field: \(key)")
            }
            XCTAssertEqual(try XCTUnwrap(json["dischargeWh"] as? Double), service.accumulatedDischargeWh, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(json["regenerationWh"] as? Double), service.accumulatedRegenerationWh, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(json["effectiveDuration"] as? Double), service.effectiveDuration, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(json["netAh"] as? Double), service.accumulatedNetAh, accuracy: 1e-12)
            XCTAssertEqual(json["averageSpeedKmh"] as? Double, service.averageSpeedKmh)
            XCTAssertEqual(json["referenceKmPerAh"] as? Double, service.referenceKmPerAh)
            XCTAssertEqual(json["windowSeconds"] as? Double, service.windowAge)
            XCTAssertEqual(json["predictionRefreshSeconds"] as? Double, service.predictionRefreshInterval)
            let intervals = try XCTUnwrap(json["intervals"] as? [[String: Any]])
            XCTAssertEqual(intervals.count, 30)
            var totalWh = 0.0
            var totalAh = 0.0
            var totalDistance = 0.0
            for interval in intervals {
                XCTAssertNotNil(interval["startedAt"])
                XCTAssertNotNil(interval["endedAt"])
                XCTAssertNotNil(interval["dischargeWh"])
                XCTAssertNotNil(interval["regenerationWh"])
                totalWh += try XCTUnwrap(interval["netWh"] as? Double)
                totalAh += try XCTUnwrap(interval["netAh"] as? Double)
                totalDistance += try XCTUnwrap(interval["distanceMeters"] as? Double)
            }
            XCTAssertEqual(totalWh, service.accumulatedNetWh, accuracy: 1e-9)
            XCTAssertEqual(totalAh, service.accumulatedNetAh, accuracy: 1e-12)
            XCTAssertEqual(totalDistance, service.accumulatedDistanceMeters, accuracy: 1e-9)
            XCTAssertNil(json["latitude"])
            XCTAssertNil(json["longitude"])
            let csv = try String(contentsOf: csvURL, encoding: .utf8)
            XCTAssertTrue(csv.contains("wh_per_km,predicted_range_km,status,reason"))
            XCTAssertTrue(csv.contains("\"valid\""))
            XCTAssertTrue(csv.contains("net_ah,average_speed_kmh,reference_km_per_ah,window_seconds,prediction_refresh_seconds"))
            let rows = csv.components(separatedBy: "\r\n")
            let values = rows[1].components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            XCTAssertGreaterThanOrEqual(values.count, 14) // Legacy columns keep their positions; additions may follow.
            XCTAssertEqual(Double(values[9]), service.accumulatedNetAh)
            XCTAssertEqual(Double(values[10]), service.averageSpeedKmh)
            XCTAssertEqual(Double(values[11]), service.referenceKmPerAh)
            XCTAssertNotEqual(jsonURL.deletingPathExtension(), csvURL.deletingPathExtension())
            clock.advance(31)
            let emptyURL = try service.exportJSON()
            defer { try? FileManager.default.removeItem(at: emptyURL) }
            let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: emptyURL)) as? [String: Any])
            XCTAssertEqual(empty["status"] as? String, "telemetryStale")
            XCTAssertEqual(empty["schemaVersion"] as? Int, 4)
            XCTAssertEqual(empty["capacitySource"] as? String, json["capacitySource"] as? String)
            XCTAssertNil(empty["nominalCapacityAh"]) // Retained evidence is not live capacity.
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertNil(empty["predictedRangeKm"])
            XCTAssertNil(empty["whPerKm"])
            XCTAssertNil(empty["averageSpeedKmh"])
            XCTAssertNil(empty["referenceKmPerAh"])
            XCTAssertEqual(empty["netAh"] as? Double, 0)
            XCTAssertEqual(empty["distanceMeters"] as? Double, service.accumulatedDistanceMeters)
            XCTAssertEqual(empty["netWh"] as? Double, service.accumulatedNetWh)
            XCTAssertEqual((empty["intervals"] as? [[String: Any]])?.count, 30)
        }
    }

    @MainActor
    func testPartialBMSTimeCoverageDoesNotBorrowUnrelatedEnergy() throws {
        try withService { service, clock in
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
    func testValidBMSAutomaticallySuppliesCapacityWithoutManualConfiguration() throws {
        try withService { service, clock in
            XCTAssertEqual(service.nominalCapacityAh, 0)
            service.ingest(snapshot: snapshot(clock.date, capacityAh: 134))
            XCTAssertEqual(service.nominalCapacityAh, 134)
            assertUnavailable(service, status: .accumulating)
            trajectory(service, clock, seconds: 30, capacityAh: 134)
            XCTAssertEqual(service.status, .valid)
            XCTAssertEqual(service.nominalCapacityAh, 134)
        }
    }

    @MainActor
    func testGPSJumpExcludesBadSegmentButKeepsValidHistory() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 1))
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            // Android excludes the jump interval but retains the still-fresh valid FIFO.
            XCTAssertNotNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.status, .valid)
        }
    }

    @MainActor
    func testNetAhUsesRemainingDifferenceNotCurrentIntegralAndWhUsesEndpointPower() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, current: 12, remainingAh: 49.8))
            service.ingest(fix: fix(clock.date, longitude: 0.0062))
            clock.advance(2)
            service.ingest(snapshot: snapshot(clock.date, current: 30, remainingAh: 49.7))
            service.ingest(fix: fix(clock.date, longitude: 0.0066))
            XCTAssertEqual(service.validIntervalCount, 32)
            XCTAssertEqual(service.effectiveDuration, 33)
            XCTAssertEqual(service.accumulatedNetAh, 0.3, accuracy: 1e-12)
            XCTAssertNotEqual(service.accumulatedNetAh, (13.5 + 21 * 2) / 3_600)
            XCTAssertEqual(service.accumulatedNetWh, 8.25 + 66 * (13.5 + 21 * 2) / 3_600, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(service.referenceKmPerAh), service.accumulatedDistanceMeters / 1_000 / 0.3, accuracy: 1e-9)
        }
    }

    @MainActor
    func testZeroMeasuredCurrentDoesNotInventWhFromReportedPowerOrCapacity() throws {
        try withService { service, clock in
            trajectory(service, clock, seconds: 30, current: 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertEqual(service.accumulatedDischargeWh, 0)
            XCTAssertEqual(service.accumulatedNetAh, 0)
            XCTAssertNil(service.referenceKmPerAh)
            XCTAssertNil(service.prediction?.predictedRangeKm)
        }
    }

    @MainActor
    func testMovingNegativeCurrentIsRegenWhileNonFiniteCurrentDoesNotClearHistory() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -990, status: 2, current: -15))
            XCTAssertNotEqual(service.status, .charging) // Snapshot callback cannot classify stationary charging.
            service.ingest(fix: fix(clock.date, longitude: 0.0062))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -990, status: 2, current: -15))
            service.ingest(fix: fix(clock.date, longitude: 0.0064))
            XCTAssertEqual(service.status, .valid)
            XCTAssertEqual(service.validIntervalCount, 32)
            XCTAssertGreaterThan(service.accumulatedRegenerationWh, 990.0 / 3_600)
            XCTAssertEqual(service.accumulatedNetWh, 990 * 29.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedNetWh, service.accumulatedDischargeWh - service.accumulatedRegenerationWh, accuracy: 1e-9)
            let wh = service.accumulatedNetWh
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: nil, current: .nan))
            XCTAssertNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.accumulatedNetWh, wh)
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
            // FIFO retains exactly 180 effective seconds, not an extra lower-bound interval.
            XCTAssertEqual(service.validIntervalCount, 180)
            XCTAssertEqual(service.accumulatedNetAh, 0, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedNetWh, 180 * 990.0 / 3_600, accuracy: 1e-9)
            let retainedDistance = service.accumulatedDistanceMeters
            XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), retainedDistance / 180 * 3.6, accuracy: 1e-9)
            XCTAssertNil(service.referenceKmPerAh)
            XCTAssertEqual(service.effectiveDuration, 180)
            settings.rangeWindowMinutes = 60
            service.applyDrivingSettings(settings)
            XCTAssertEqual(service.validIntervalCount, 180)
            XCTAssertEqual(service.accumulatedDistanceMeters, retainedDistance)
            XCTAssertEqual(service.nominalCapacityAh, 100)
        }
    }

    @MainActor
    func testPredictionCadenceCachesCoefficientsButCurrentEnergyAndEvidenceStayLive() throws {
        try withService { service, clock in
            var settings = DrivingSettings.defaults
            settings.rangeRefreshSeconds = 60
            service.applyDrivingSettings(settings)
            seedValidWindow(service, clock)
            let initial = try XCTUnwrap(service.prediction?.predictedRangeKm)
            let sampledConsumption = try XCTUnwrap(service.effectiveWhPerKm)
            let sampledSpeed = try XCTUnwrap(service.averageSpeedKmh)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, current: 45))
            service.ingest(fix: fix(clock.date, longitude: 0.0062))
            XCTAssertEqual(service.prediction?.predictedRangeKm, initial)
            XCTAssertEqual(service.accumulatedNetWh, 8.25 + 66 * 30.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(service.effectiveDuration, 31)
            XCTAssertEqual(service.effectiveWhPerKm, sampledConsumption)
            XCTAssertEqual(service.averageSpeedKmh, sampledSpeed)
            XCTAssertEqual(service.accumulatedNetAh, 0)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, current: 45, remainingAh: 49.5))
            let live = try XCTUnwrap(service.prediction?.predictedRangeKm)
            let numerator = try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 49.5, capacityAh: 100))
            let denominator = try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 50, capacityAh: 100))
            XCTAssertEqual(live, initial * numerator / denominator, accuracy: 1e-9)
            service.applyDrivingSettings(settings) // Same config does not bypass cadence.
            XCTAssertEqual(service.prediction?.predictedRangeKm, live)
            settings.rangeRefreshSeconds = 10
            service.applyDrivingSettings(settings)
            XCTAssertLessThan(try XCTUnwrap(service.prediction?.predictedRangeKm), live)
            XCTAssertGreaterThan(try XCTUnwrap(service.effectiveWhPerKm), sampledConsumption)
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
                    service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2))
                    service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2))
                    service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
                    assertUnavailable(service, status: .charging)
                    XCTAssertEqual(service.nominalCapacityAh, 100)
                case 1:
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, status: 5))
                    assertUnavailable(service, status: .noValidIntervals)
                    XCTAssertEqual(service.nominalCapacityAh, 0)
                case 2:
                    clock.advance(31)
                    service.refresh()
                    assertUnavailable(service, status: .telemetryStale)
                    XCTAssertEqual(service.nominalCapacityAh, 0)
                case 3:
                    service.setConnectionReady(false)
                    assertUnavailable(service, status: .disconnected)
                    XCTAssertEqual(service.nominalCapacityAh, 0)
                case 4:
                    clock.advance(1)
                    service.ingest(snapshot: snapshot(clock.date, remainingAh: 101))
                    assertUnavailable(service, status: .capacityInvalid)
                    XCTAssertEqual(service.nominalCapacityAh, 0)
                case 5:
                    for _ in 0..<31 {
                        clock.advance(1)
                        service.ingest(snapshot: snapshot(clock.date))
                    }
                    assertUnavailable(service, status: .telemetryStale)
                    XCTAssertEqual(service.nominalCapacityAh, 100) // Only GPS is stale.
                default:
                    for _ in 0..<31 {
                        clock.advance(1)
                        service.ingest(snapshot: snapshot(clock.date))
                        service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
                    }
                    XCTAssertNil(service.prediction?.predictedRangeKm)
                }
            }
        }
    }

    @MainActor
    func testClearAndResetPreserveConfigurationOtherDevicesAndExportedFile() throws {
        try withService { service, clock in
            service.setDeviceID(deviceB)
            seedValidWindow(service, clock, capacityAh: 48, remainingAh: 24)
            let whB = service.accumulatedNetWh
            service.setDeviceID(deviceA)
            let legacyKey = "com.zjsf.anturide.range.capacity.\(deviceA.uuidString)"
            clock.defaults.set(72.0, forKey: legacyKey)
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
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.windowAge, 1_800)
            XCTAssertEqual(service.predictionRefreshInterval, 60)
            service.reset()
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.windowAge, 1_800)
            XCTAssertEqual(service.predictionRefreshInterval, 60)
            service.setDeviceID(deviceB)
            XCTAssertEqual(clock.defaults.double(forKey: legacyKey), 72) // Reset does not manage legacy preferences.
            XCTAssertEqual(service.nominalCapacityAh, 0)
            XCTAssertEqual(service.accumulatedNetWh, whB)
            XCTAssertEqual(service.accumulatedNetAh, 0)
            service.ingest(snapshot: snapshot(clock.date, remainingAh: 24, capacityAh: 48))
            XCTAssertEqual(service.nominalCapacityAh, 48)
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

    @MainActor
    func testDurationDistanceAndDischargeThresholdsAreIndependent() throws {
        for (seconds, meters, wh) in [(29, 300.0, 8.0), (30, 199.9, 8.0), (30, 300.0, 4.99), (30, 200.1, 5.01)] {
            try withService { service, clock in
                trajectory(service, clock, seconds: seconds, metersPerSecond: meters / Double(seconds),
                           current: wh * 3_600 / (66 * Double(seconds)), power: nil)
                XCTAssertEqual(service.effectiveDuration, Double(seconds), accuracy: 1e-9)
                XCTAssertEqual(service.accumulatedDistanceMeters, meters, accuracy: 0.001)
                XCTAssertEqual(service.accumulatedDischargeWh, wh, accuracy: 1e-9)
                if seconds == 30 && meters > 200 && wh > 5 {
                    XCTAssertEqual(service.status, .valid)
                    XCTAssertNotNil(service.prediction?.predictedRangeKm)
                } else {
                    XCTAssertNil(service.prediction?.predictedRangeKm)
                    XCTAssertNotEqual(service.status, .valid)
                }
            }
        }
    }

    @MainActor
    func testSpeedThresholdUsesThreeKmhNotOneMeterPerSecondOrInstantaneousGPS() throws {
        for kmh in [2.99, 3.2] {
            try withService { service, clock in
                // 0.9m/s = 3.24km/h; the former 1m/s check incorrectly rejected it.
                trajectory(service, clock, seconds: 300, metersPerSecond: kmh / 3.6, speed: 0.9)
                if kmh < 3 {
                    XCTAssertEqual(service.effectiveDuration, 0)
                    XCTAssertNil(service.prediction?.predictedRangeKm)
                } else {
                    XCTAssertEqual(service.status, .valid)
                    XCTAssertGreaterThan(service.accumulatedDistanceMeters, 200)
                    XCTAssertEqual(try XCTUnwrap(service.averageSpeedKmh), kmh, accuracy: 1e-6)
                }
            }
        }
    }

    @MainActor
    func testDischargeAboveFiveWhDoesNotBypassNetEnergyThresholdAfterRegen() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            for second in 31...43 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, power: -990, status: 2, current: -15))
                service.ingest(fix: fix(clock.date, longitude: Double(second) * 0.0002))
            }
            XCTAssertGreaterThan(service.accumulatedDischargeWh, 5)
            XCTAssertLessThan(service.accumulatedNetWh, 5)
            XCTAssertGreaterThan(service.effectiveDuration, 30)
            XCTAssertGreaterThan(service.accumulatedDistanceMeters, 200)
            assertUnavailable(service, status: .nonPositiveNetEnergy)
        }
    }

    @MainActor
    func testMissingReportedPowerStillAccumulatesMeasuredVoltageTimesCurrent() throws {
        try withService { service, clock in
            trajectory(service, clock, seconds: 30, power: nil)
            XCTAssertEqual(service.status, .valid)
            XCTAssertEqual(service.accumulatedNetWh, 8.25, accuracy: 1e-9)
        }
    }

    @MainActor
    func testReportedPowerSignConflictAboveFiftyWattsExcludesBadSegmentOnly() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let wh = service.accumulatedNetWh
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -51))
            service.ingest(fix: fix(clock.date, longitude: 0.0062))
            XCTAssertNil(service.prediction?.predictedRangeKm)
            XCTAssertEqual(service.accumulatedNetWh, wh)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: nil))
            service.ingest(fix: fix(clock.date, longitude: 0.0064))
            XCTAssertEqual(service.validIntervalCount, 30)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -50)) // Strictly >50W, not >=50W.
            service.ingest(fix: fix(clock.date, longitude: 0.0066))
            XCTAssertEqual(service.validIntervalCount, 31)
            XCTAssertEqual(service.accumulatedNetWh, wh + 990.0 / 3_600, accuracy: 1e-9)
        }
    }

    @MainActor
    func testNoPastBMSCannotBorrowFutureCallbackOrBackfillAlreadyRejectedGPS() throws {
        try withService { service, clock in
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1)
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date.addingTimeInterval(-0.5), longitude: 0.0003))
            XCTAssertEqual(service.validIntervalCount, 0) // Latest BMS lies after GPS timestamp.
            service.ingest(fix: fix(clock.date, longitude: 0.0004))
            XCTAssertEqual(service.validIntervalCount, 0)
            clock.advance(1)
            service.ingest(fix: fix(clock.date, longitude: 0.0006))
            XCTAssertEqual(service.validIntervalCount, 1)
            XCTAssertEqual(service.accumulatedNetWh, 990.0 / 3_600, accuracy: 1e-9)
        }
    }

    @MainActor
    func testFreshBMSAtEachEndCannotBridgeElevenSecondGPSGap() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(11)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0082))
            XCTAssertEqual(service.effectiveDuration, 30)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0084))
            XCTAssertEqual(service.effectiveDuration, 31)
        }
    }

    @MainActor
    func testColdRestorationPersistsEffectiveDrivingEvidencePerUUIDWithoutLiveEndpoints() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            let whA = service.accumulatedNetWh
            service.setDeviceID(deviceB)
            trajectory(service, clock, seconds: 30, capacityAh: 80)
            let whB = service.accumulatedNetWh
            // 真实冷恢复的前置：BLE 断开（断连会 flush 完整驾驶证据，不受节流持久化截断）。
            service.setConnectionReady(false)
            clock.advance(3_600)

            let restored = RangeService(defaults: clock.defaults, clock: { clock.date })
            restored.setConnectionReady(true)
            restored.setLocationUpdating(true)
            restored.setDeviceID(deviceA)
            XCTAssertEqual(restored.nominalCapacityAh, 0)
            XCTAssertEqual(restored.accumulatedNetWh, whA, accuracy: 1e-9)
            XCTAssertEqual(restored.effectiveDuration, 30)
            XCTAssertNil(restored.prediction?.predictedRangeKm)
            restored.ingest(snapshot: snapshot(clock.date))
            restored.ingest(fix: fix(clock.date, longitude: 0.1))
            XCTAssertEqual(restored.validIntervalCount, 30)
            XCTAssertNil(restored.prediction?.predictedRangeKm)
            clock.advance(1)
            restored.ingest(snapshot: snapshot(clock.date))
            restored.ingest(fix: fix(clock.date, longitude: 0.1002))
            XCTAssertEqual(restored.validIntervalCount, 31)
            XCTAssertEqual(restored.accumulatedNetWh, whA + 990.0 / 3_600, accuracy: 1e-9)
            XCTAssertEqual(restored.status, .valid)

            restored.setDeviceID(deviceB)
            XCTAssertEqual(restored.nominalCapacityAh, 0)
            XCTAssertEqual(restored.accumulatedNetWh, whB, accuracy: 1e-9)
            XCTAssertEqual(restored.effectiveDuration, 30)
        }
    }

    @MainActor
    func testRemainingAhJumpClearsOnlyDrivingWindowAndDoesNotInventBoundaryEnergy() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, remainingAh: 51.1)) // > average(|I|)*dt/3600 + 1% capacity.
            XCTAssertEqual(service.effectiveDuration, 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            service.ingest(fix: fix(clock.date, longitude: 0.0062))
            XCTAssertEqual(service.effectiveDuration, 0) // No energy is fabricated across the reset.
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, remainingAh: 51.1))
            service.ingest(fix: fix(clock.date, longitude: 0.0064))
            XCTAssertEqual(service.effectiveDuration, 1)
            XCTAssertEqual(service.accumulatedNetWh, 990.0 / 3_600, accuracy: 1e-9)
        }
    }

    @MainActor
    func testCapacityJumpDuringParkingChargeClearsOldChargingState() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            for _ in 0..<2 {
                clock.advance(1)
                service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2))
                service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
            }
            assertUnavailable(service, status: .charging)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2, remainingAh: 52))
            XCTAssertEqual(service.effectiveDuration, 0)
            assertUnavailable(service, status: .noValidIntervals)
            service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
            assertUnavailable(service, status: .noValidIntervals)
            // A new complete stationary interval may legitimately re-enter charging.
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: -132, status: 2, current: -2, remainingAh: 52))
            service.ingest(fix: fix(clock.date, longitude: 0.006, speed: 0))
            assertUnavailable(service, status: .charging)
        }
    }

    @MainActor
    func testRemainingAhJumpToleranceIncludesAverageCurrentElapsedTimeAndCapacity() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(10)
            // Tolerance is average(|15A|, |30A|)*10/3600 + 100Ah*1% = 1.0625Ah.
            service.ingest(snapshot: snapshot(clock.date, current: 30, remainingAh: 48.95)) // 1.05Ah remains explainable.
            XCTAssertEqual(service.effectiveDuration, 30)
            XCTAssertEqual(service.accumulatedNetWh, 8.25, accuracy: 1e-9)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, current: 30, remainingAh: 47.8)) // 1.15Ah jump exceeds tolerance.
            XCTAssertEqual(service.effectiveDuration, 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
        }
    }

    @MainActor
    func testSampleTimestampRollbackClearsHistoryBeforeAcceptingNewEpoch() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date.addingTimeInterval(-2)))
            XCTAssertEqual(service.effectiveDuration, 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            service.ingest(fix: fix(clock.date, longitude: 0))
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date))
            service.ingest(fix: fix(clock.date, longitude: 0.0002))
            XCTAssertEqual(service.effectiveDuration, 1)
            XCTAssertEqual(service.accumulatedNetWh, 990.0 / 3_600, accuracy: 1e-9)
        }
    }

    @MainActor
    func testWallClockRollbackClearsHistoryAndAllowsFreshSamplesInNewEpoch() throws {
        try withService { service, clock in
            seedValidWindow(service, clock)
            clock.advance(-120)
            service.refresh()
            XCTAssertEqual(service.effectiveDuration, 0)
            XCTAssertEqual(service.accumulatedNetWh, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
            trajectory(service, clock, seconds: 30)
            XCTAssertEqual(service.effectiveDuration, 30)
            XCTAssertEqual(service.validIntervalCount, 30)
            XCTAssertEqual(service.status, .valid)
        }
    }

    @MainActor
    func testNetAhComesFromRemainingDifferenceAndPartialFIFOClipsItProportionally() throws {
        try withService { service, clock in
            var settings = DrivingSettings.defaults
            settings.rangeWindowMinutes = 3
            service.applyDrivingSettings(settings)
            service.ingest(snapshot: snapshot(clock.date, current: 15, remainingAh: 50))
            service.ingest(fix: fix(clock.date, longitude: 0))
            for second in stride(from: 10, through: 180, by: 10) {
                clock.advance(10)
                service.ingest(snapshot: snapshot(clock.date, current: 15, remainingAh: 50 - Double(second) * 0.02))
                service.ingest(fix: fix(clock.date, longitude: Double(second) * 0.00018))
            }
            clock.advance(5)
            service.ingest(snapshot: snapshot(clock.date, current: 15, remainingAh: 46.3))
            service.ingest(fix: fix(clock.date, longitude: 0.0333))
            XCTAssertEqual(service.effectiveDuration, 180)
            XCTAssertEqual(service.validIntervalCount, 19)
            // The first 10s interval carries 0.2Ah; FIFO keeps half (=0.1Ah),
            // then 17*0.2Ah and the final 5s interval's 0.1Ah.
            XCTAssertEqual(service.accumulatedNetAh, 3.6, accuracy: 1e-9)
            XCTAssertNotEqual(service.accumulatedNetAh, 15 * 180.0 / 3_600)
            XCTAssertEqual(service.accumulatedNetWh, 49.5, accuracy: 1e-9)
            XCTAssertEqual(service.accumulatedDistanceMeters, 3_602.716, accuracy: 0.1)
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
    private func seedValidWindow(_ service: RangeService, _ clock: Clock,
                                 capacityAh: Double = 100, remainingAh: Double = 50) {
        service.ingest(snapshot: snapshot(clock.date, remainingAh: remainingAh, capacityAh: capacityAh))
        service.ingest(fix: fix(clock.date, longitude: 0))
        for second in 1...30 {
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, remainingAh: remainingAh, capacityAh: capacityAh))
            service.ingest(fix: fix(clock.date, longitude: Double(second) * 0.0002))
        }
        // Re-pair fresh inputs after a sampling restart so configured cadence fixtures
        // expose the complete window without using a removed manual-capacity cache hook.
        if service.predictionRefreshInterval > 0 {
            service.setLocationUpdating(false)
            service.setLocationUpdating(true)
            service.ingest(snapshot: snapshot(clock.date, remainingAh: remainingAh, capacityAh: capacityAh))
            service.ingest(fix: fix(clock.date, longitude: 0.006))
        }
        XCTAssertEqual(service.status, .valid)
    }

    @MainActor
    private func trajectory(_ service: RangeService, _ clock: Clock, seconds: Int,
                            metersPerSecond: Double? = nil, current: Double = 15,
                            speed: Double = 22, power: Double? = 1_000, capacityAh: Double = 100) {
        let metersPerDegree = 6_371_008.8 * Double.pi / 180
        let step = metersPerSecond.map { $0 / metersPerDegree } ?? 0.0002
        service.ingest(snapshot: snapshot(clock.date, power: power, current: current, capacityAh: capacityAh))
        service.ingest(fix: fix(clock.date, longitude: 0, speed: speed))
        for second in 1...seconds {
            clock.advance(1)
            service.ingest(snapshot: snapshot(clock.date, power: power, current: current, capacityAh: capacityAh))
            service.ingest(fix: fix(clock.date, longitude: Double(second) * step, speed: speed))
        }
    }

    @MainActor
    private func assertUnavailable(_ service: RangeService, status: RangePredictionStatus,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.status, status, file: file, line: line)
        XCTAssertNil(service.prediction?.predictedRangeKm, file: file, line: line)
        XCTAssertNil(service.effectiveWhPerKm, file: file, line: line)
        XCTAssertNil(service.averageSpeedKmh, file: file, line: line)
        XCTAssertNil(service.referenceKmPerAh, file: file, line: line)
        // Ordinary withdrawal preserves accumulated history; explicit clear/reset removes it.
        XCTAssertFalse(service.reasonText.isEmpty, file: file, line: line)
    }

    private func snapshot(_ date: Date, power: Double? = 1_000, status: Int = 3,
                          frameLength: Int = 32, current: Double = 15, remainingAh: Double = 50,
                          voltage: Double = 66, capacityAh: Double = 100) -> BmsSnapshot {
        BmsSnapshot(receivedAt: date, totalVoltage: voltage, current: current, soc: 50,
                    capacityAh: capacityAh, remainingAh: remainingAh, temperatures: [], mosTemperature: 0,
                    balancerTemperature: 0, cellVoltagesMillivolts: [3_300], power: power,
                    statusCode: status, frameLength: frameLength)
    }
    private func fix(_ date: Date, longitude: Double, speed: Double = 22) -> GpsFix {
        GpsFix(timestamp: date, latitude: 0, longitude: longitude, speed: speed, horizontalAccuracy: 5)
    }
}
