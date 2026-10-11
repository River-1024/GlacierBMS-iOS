import ANTuRideDomain
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import ANTuRide

/// 隔离 UserDefaults/可控时钟，不创建蓝牙 manager；不冒充真机 BLE 验收。
final class DrivingSettingsStoreTests: XCTestCase {
    @MainActor
    func testFreshStoreSaveReloadAndIndependentPreferences() throws {
        try withDefaults { defaults in
            let store = DrivingSettingsStore(defaults: defaults)
            XCTAssertEqual(store.settings, .defaults)
            XCTAssertNil(defaults.object(forKey: DrivingSettingsStore.key))
            var candidate = store.settings
            candidate.appThemeMode = .dark
            candidate.valueScale = 1.4
            candidate.rangeWindowMinutes = 20
            candidate.bmsAutoConnectEnabled = false
            try store.save(candidate)
            XCTAssertEqual(store.settings, candidate)
            XCTAssertEqual(DrivingSettingsStore(defaults: defaults).settings, candidate)
            XCTAssertTrue(store.settings.controllerAutoConnectEnabled)
        }
    }

    @MainActor
    func testInvalidSaveDoesNotWriteOrPublish() throws {
        try withDefaults { defaults in
            let store = DrivingSettingsStore(defaults: defaults)
            try store.save(.defaults)
            let before = defaults.data(forKey: DrivingSettingsStore.key)
            var events = 0
            let subscription = store.$settings.dropFirst().sink { _ in events += 1 }
            var invalid = store.settings
            invalid.tempYellowUpperC = -100
            XCTAssertThrowsError(try store.save(invalid))
            XCTAssertEqual(defaults.data(forKey: DrivingSettingsStore.key), before)
            XCTAssertEqual(store.settings, .defaults)
            XCTAssertEqual(events, 0)
            withExtendedLifetime(subscription) {}
        }
    }

    @MainActor
    func testSavingStaleDrivingDraftPreservesLatestRangeSettings() throws {
        try withDefaults { defaults in
            let store = DrivingSettingsStore(defaults: defaults)
            var staleDraft = store.settings
            staleDraft.appThemeMode = .dark
            staleDraft.bluetoothRefreshIntervalMs = 250
            staleDraft.controllerAutoConnectEnabled = false
            var rangeUpdate = store.settings
            rangeUpdate.rangeWindowMinutes = 30
            rangeUpdate.rangeRefreshSeconds = 45
            try store.save(rangeUpdate)

            try store.saveDrivingPreferences(staleDraft)

            var expected = staleDraft
            expected.rangeWindowMinutes = 30
            expected.rangeRefreshSeconds = 45
            XCTAssertEqual(store.settings, expected)
            XCTAssertEqual(DrivingSettingsStore(defaults: defaults).settings, expected)
        }
    }

    @MainActor
    func testRestoreDrivingPreferencesKeepsRangeHomeUUIDCapacityAndHistory() throws {
        try withDefaults { defaults in
            let id = UUID()
            let capacityKey = "com.zjsf.anturide.range.capacity.\(id.uuidString)"
            defaults.set(id.uuidString, forKey: BmsBluetoothService.rememberedDeviceDefaultsKey)
            defaults.set(100.0, forKey: capacityKey)
            defaults.set(Data([1, 2, 3]), forKey: "history.sentinel")
            let homeLayout = try XCTUnwrap(HomeParameterPrefs.encode(.androidDefault))
            defaults.set(homeLayout, forKey: HomeParameterPrefs.key)
            let store = DrivingSettingsStore(defaults: defaults)
            var changed = store.settings
            changed.rangeWindowMinutes = 30
            changed.rangeRefreshSeconds = 45
            changed.appThemeMode = .dark
            changed.valueScale = 1.4
            changed.bluetoothRefreshIntervalMs = 250
            changed.bmsAutoConnectEnabled = false
            changed.controllerAutoConnectEnabled = false
            try store.save(changed)

            try store.restoreDrivingPreferencesDefaults()

            var expected = DrivingSettings.defaults
            expected.rangeWindowMinutes = 30
            expected.rangeRefreshSeconds = 45
            XCTAssertEqual(store.settings, expected)
            XCTAssertEqual(DrivingSettingsStore(defaults: defaults).settings, expected)
            XCTAssertEqual(defaults.string(forKey: BmsBluetoothService.rememberedDeviceDefaultsKey), id.uuidString)
            XCTAssertEqual(defaults.double(forKey: capacityKey), 100)
            XCTAssertEqual(defaults.data(forKey: "history.sentinel"), Data([1, 2, 3]))
            XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), homeLayout)
        }
    }

    @MainActor
    func testRestoringRangeCadenceKeepsDrivingDeviceDataAndAppliesService() throws {
        try withDefaults { defaults in
            let id = UUID()
            let capacityKey = "com.zjsf.anturide.range.capacity.\(id.uuidString)"
            defaults.set(id.uuidString, forKey: BmsBluetoothService.rememberedDeviceDefaultsKey)
            defaults.set(112.0, forKey: capacityKey)
            defaults.set(Data([4, 5, 6]), forKey: "history.sentinel")
            let homeLayout = try XCTUnwrap(HomeParameterPrefs.encode(.androidDefault))
            defaults.set(homeLayout, forKey: HomeParameterPrefs.key)
            let store = DrivingSettingsStore(defaults: defaults)
            var original = store.settings
            original.rangeWindowMinutes = 30
            original.rangeRefreshSeconds = 45
            original.appThemeMode = .dark
            original.bluetoothRefreshIntervalMs = 250
            original.valueScale = 1.4
            original.bmsAutoConnectEnabled = false
            original.controllerAutoConnectEnabled = false
            try store.save(original)
            let service = RangeService(defaults: defaults)
            service.setDeviceID(id)
            let subscription = store.$settings.sink { service.applyDrivingSettings($0) }
            XCTAssertEqual(service.windowAge, 1800)
            XCTAssertEqual(service.predictionRefreshInterval, 45)

            try store.saveRangePreferences(windowMinutes: DrivingSettings.defaults.rangeWindowMinutes,
                                           refreshSeconds: DrivingSettings.defaults.rangeRefreshSeconds)

            var expected = original
            expected.rangeWindowMinutes = 15
            expected.rangeRefreshSeconds = 10
            XCTAssertEqual(store.settings, expected)
            XCTAssertEqual(DrivingSettingsStore(defaults: defaults).settings, expected)
            XCTAssertEqual(service.windowAge, 900)
            XCTAssertEqual(service.predictionRefreshInterval, 10)
            XCTAssertEqual(service.nominalCapacityAh, 112)
            XCTAssertEqual(service.deviceID, id)
            XCTAssertEqual(defaults.string(forKey: BmsBluetoothService.rememberedDeviceDefaultsKey), id.uuidString)
            XCTAssertEqual(defaults.double(forKey: capacityKey), 112)
            XCTAssertEqual(defaults.data(forKey: "history.sentinel"), Data([4, 5, 6]))
            XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), homeLayout)
            withExtendedLifetime(subscription) {}
        }
    }

    @MainActor
    func testInvalidDrivingPreferencesDoNotWriteOrPublish() throws {
        try withDefaults { defaults in
            let store = DrivingSettingsStore(defaults: defaults)
            var saved = store.settings
            saved.rangeWindowMinutes = 30
            saved.rangeRefreshSeconds = 45
            try store.save(saved)
            let before = defaults.data(forKey: DrivingSettingsStore.key)
            let noticeBefore = store.notice
            var settingsEvents = 0
            var noticeEvents = 0
            let settingsSubscription = store.$settings.dropFirst().sink { _ in settingsEvents += 1 }
            let noticeSubscription = store.$notice.dropFirst().sink { _ in noticeEvents += 1 }
            var invalidDisplay = saved
            invalidDisplay.tempYellowUpperC = -100
            var invalidRange = saved
            invalidRange.rangeWindowMinutes = 1
            for invalid in [invalidDisplay, invalidRange] {
                XCTAssertThrowsError(try store.saveDrivingPreferences(invalid))
                XCTAssertEqual(defaults.data(forKey: DrivingSettingsStore.key), before)
                XCTAssertEqual(store.settings, saved)
                XCTAssertEqual(store.notice, noticeBefore)
                XCTAssertEqual(settingsEvents, 0)
                XCTAssertEqual(noticeEvents, 0)
            }
            withExtendedLifetime((settingsSubscription, noticeSubscription)) {}
        }
    }

    @MainActor
    func testCorruptWrongTypeAndOutOfRangeLoadPreserveOriginalStorage() throws {
        try withDefaults { defaults in
            let corrupt = Data("not JSON".utf8)
            defaults.set(corrupt, forKey: DrivingSettingsStore.key)
            let store = DrivingSettingsStore(defaults: defaults)
            XCTAssertEqual(store.settings, .defaults)
            XCTAssertNotNil(store.notice)
            XCTAssertEqual(defaults.data(forKey: DrivingSettingsStore.key), corrupt)
            defaults.set("wrong type", forKey: DrivingSettingsStore.key)
            store.reload()
            XCTAssertEqual(store.settings, .defaults)
            XCTAssertEqual(defaults.string(forKey: DrivingSettingsStore.key), "wrong type")
            var unsafe = DrivingSettings()
            unsafe.rangeWindowMinutes = 1
            unsafe.rangeRefreshSeconds = 600
            let original = try JSONEncoder().encode(unsafe)
            defaults.set(original, forKey: DrivingSettingsStore.key)
            store.reload()
            XCTAssertEqual(store.settings.rangeWindowMinutes, 3)
            XCTAssertEqual(store.settings.rangeRefreshSeconds, 60)
            XCTAssertEqual(defaults.data(forKey: DrivingSettingsStore.key), original)
        }
    }

    @MainActor
    func testRestoreOnlyWritesDrivingKeyAndKeepsUUIDCapacityAndHistory() throws {
        try withDefaults { defaults in
            let id = UUID()
            let capacityKey = "com.zjsf.anturide.range.capacity.\(id.uuidString)"
            defaults.set(id.uuidString, forKey: BmsBluetoothService.rememberedDeviceDefaultsKey)
            defaults.set(100.0, forKey: capacityKey)
            defaults.set(Data([1, 2, 3]), forKey: "history.sentinel")
            let store = DrivingSettingsStore(defaults: defaults)
            var changed = DrivingSettings()
            changed.bmsAutoConnectEnabled = false
            changed.controllerAutoConnectEnabled = false
            try store.save(changed)
            try store.restoreDefaults()
            XCTAssertEqual(store.settings, .defaults)
            XCTAssertEqual(defaults.string(forKey: BmsBluetoothService.rememberedDeviceDefaultsKey), id.uuidString)
            XCTAssertEqual(defaults.double(forKey: capacityKey), 100)
            XCTAssertEqual(defaults.data(forKey: "history.sentinel"), Data([1, 2, 3]))
        }
    }

    @MainActor
    func testPublishedConsumerUsesEventValueAndThemeMapping() throws {
        try withDefaults { defaults in
            let store = DrivingSettingsStore(defaults: defaults)
            let bms = BmsBluetoothService(defaults: defaults, startupAutoConnectEnabled: false,
                                          queryIntervalMs: 1000, createsBluetoothManager: false)
            let range = RangeService(defaults: defaults)
            var theme: ColorScheme?
            var oldRead: DrivingSettings?
            let subscription = store.$settings.sink { settings in
                theme = settings.preferredColorScheme
                bms.applyDrivingSettings(settings)
                range.applyDrivingSettings(settings)
                oldRead = store.settings
            }
            XCTAssertNil(theme)
            XCTAssertEqual(range.windowAge, 900)
            var changed = DrivingSettings()
            changed.appThemeMode = .dark
            changed.bluetoothRefreshIntervalMs = 2500
            changed.rangeWindowMinutes = 30
            changed.rangeRefreshSeconds = 20
            try store.save(changed)
            XCTAssertEqual(theme, .dark)
            XCTAssertEqual(bms.effectiveQueryInterval, 2.5)
            XCTAssertEqual(range.windowAge, 1800)
            XCTAssertEqual(range.predictionRefreshInterval, 20)
            XCTAssertEqual(oldRead, .defaults) // Published 在 willSet 发布。
            changed.appThemeMode = .light
            try store.save(changed)
            XCTAssertEqual(theme, .light)
            changed.appThemeMode = .system
            try store.save(changed)
            XCTAssertNil(theme)
            withExtendedLifetime(subscription) {}
        }
    }

    @MainActor
    func testBMSQueryIntervalClampsAndDoesNotConnectWhenSettingsChange() throws {
        try withDefaults { defaults in
            let bms = BmsBluetoothService(defaults: defaults, startupAutoConnectEnabled: false,
                                          queryIntervalMs: 1, createsBluetoothManager: false)
            XCTAssertEqual(bms.effectiveQueryInterval, 0.1)
            var changed = DrivingSettings()
            changed.bluetoothRefreshIntervalMs = Int.max
            bms.applyDrivingSettings(changed)
            XCTAssertEqual(bms.effectiveQueryInterval, 60)
            XCTAssertEqual(bms.state, .idle)
            XCTAssertNil(bms.connectedDeviceID)
            bms.disconnect()
            bms.applyDrivingSettings(.defaults)
            XCTAssertEqual(bms.state, .disconnected)
            XCTAssertNil(bms.connectedDeviceID)
        }
    }

    func testStartupPolicyOnlyConsumesFirstPoweredOnAndNeverRetries() {
        let id = UUID()
        var policy = BmsStartupConnectionPolicy()
        XCTAssertNil(policy.consumeTarget(poweredOn: false, enabled: true, rememberedID: id, hasActiveSession: false))
        XCTAssertFalse(policy.consumed)
        XCTAssertEqual(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false), id)
        XCTAssertTrue(policy.consumed)
        XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false))
    }

    func testStartupDisabledMissingIdentityOrManualSessionConsumesOpportunity() {
        let cases: [(Bool, UUID?, Bool)] = [(false, UUID(), false), (true, nil, false), (true, UUID(), true)]
        for (enabled, id, active) in cases {
            var policy = BmsStartupConnectionPolicy()
            XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: enabled, rememberedID: id, hasActiveSession: active))
            XCTAssertTrue(policy.consumed)
            XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: UUID(), hasActiveSession: false))
        }
        var manualDisconnect = BmsStartupConnectionPolicy()
        manualDisconnect.suppressForRun()
        XCTAssertNil(manualDisconnect.consumeTarget(poweredOn: true, enabled: true, rememberedID: UUID(), hasActiveSession: false))
    }

    @MainActor
    func testIndependentRangeRetainsFiveMinuteImmediateContractAndProductionOverrides() throws {
        try withDefaults { defaults in
            let service = RangeService(defaults: defaults)
            XCTAssertEqual(service.windowAge, 300)
            XCTAssertEqual(service.predictionRefreshInterval, 0)
            service.applyDrivingSettings(.defaults)
            XCTAssertEqual(service.windowAge, 900)
            XCTAssertEqual(service.predictionRefreshInterval, 10)
        }
    }

    @MainActor
    func testConfiguredRangeThrottlesPredictionButDoesNotThrottleSafety() throws {
        try withRange { service, clock in
            var config = DrivingSettings()
            config.rangeRefreshSeconds = 10
            service.applyDrivingSettings(config)
            seed(service, clock)
            let first = try XCTUnwrap(service.prediction?.predictedRangeKm)
            for second in 2...10 {
                clock.date = clock.start.addingTimeInterval(Double(second))
                service.ingest(snapshot: snapshot(clock.date, power: 2000))
                service.ingest(fix: fix(clock.date, longitude: Double(second) * 0.0002))
            }
            XCTAssertEqual(service.prediction?.predictedRangeKm, first)
            clock.date = clock.start.addingTimeInterval(11)
            service.ingest(snapshot: snapshot(clock.date, power: 2000))
            service.ingest(fix: fix(clock.date, longitude: 0.0022))
            XCTAssertLessThan(try XCTUnwrap(service.prediction?.predictedRangeKm), first)
            // 刷新间隔尚未到期，充电必须立即撤下预测。
            clock.date = clock.start.addingTimeInterval(12)
            service.ingest(snapshot: snapshot(clock.date, power: -100))
            XCTAssertEqual(service.status, .charging)
            XCTAssertNil(service.prediction?.predictedRangeKm)
        }
    }

    @MainActor
    func testFifteenMinuteWindowRetainsMoreThanOld256IntervalCapAndShorteningPrunes() throws {
        try withRange { service, clock in
            service.applyDrivingSettings(.defaults)
            seed(service, clock)
            for second in 2...420 {
                clock.date = clock.start.addingTimeInterval(Double(second))
                service.ingest(snapshot: snapshot(clock.date))
                service.ingest(fix: fix(clock.date, longitude: Double(second) * 0.0002))
            }
            XCTAssertEqual(service.validIntervalCount, 420)
            var config = DrivingSettings()
            config.rangeWindowMinutes = 3
            service.applyDrivingSettings(config)
            XCTAssertEqual(service.windowAge, 180)
            XCTAssertEqual(service.validIntervalCount, 181) // 下界端点包含。
            clock.date = clock.date.addingTimeInterval(6)
            service.refresh()
            XCTAssertEqual(service.status, .telemetryStale)
            XCTAssertEqual(service.validIntervalCount, 0)
            XCTAssertNil(service.prediction?.predictedRangeKm)
        }
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "DrivingSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private final class Clock {
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        lazy var date = start
    }

    @MainActor
    private func withRange(_ body: (RangeService, Clock) throws -> Void) throws {
        try withDefaults { defaults in
            let clock = Clock()
            let service = RangeService(defaults: defaults, clock: { clock.date })
            service.setConnectionReady(true)
            service.setLocationUpdating(true)
            service.setDeviceID(UUID())
            XCTAssertTrue(service.updateNominalCapacityAh(100))
            try body(service, clock)
        }
    }

    @MainActor
    private func seed(_ service: RangeService, _ clock: Clock) {
        service.ingest(snapshot: snapshot(clock.date))
        service.ingest(fix: fix(clock.date, longitude: 0))
        clock.date = clock.start.addingTimeInterval(1)
        service.ingest(snapshot: snapshot(clock.date))
        service.ingest(fix: fix(clock.date, longitude: 0.0002))
    }

    private func snapshot(_ date: Date, power: Double = 1000) -> BmsSnapshot {
        BmsSnapshot(receivedAt: date, totalVoltage: 66, current: power < 0 ? -15 : 15, soc: 50,
                    capacityAh: 100, remainingAh: 50, temperatures: [], mosTemperature: 0,
                    balancerTemperature: 0, cellVoltagesMillivolts: [3300], power: power,
                    statusCode: power < 0 ? 2 : 3, frameLength: 32)
    }
    private func fix(_ date: Date, longitude: Double) -> GpsFix {
        GpsFix(timestamp: date, latitude: 0, longitude: longitude, speed: 22, horizontalAccuracy: 5)
    }
}
