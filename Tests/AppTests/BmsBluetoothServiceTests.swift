import ANTuRideDomain
import CoreBluetooth
import Foundation
import XCTest
@testable import ANTuRide

/// 不创建 CBCentralManager；验证生产共用的状态/存储/回调边界，不替代 BLE 真机验收。
final class BmsBluetoothServiceTests: XCTestCase {
    @MainActor
    func testInitialForegroundIsFalseAndRememberedIdentityLoadsWithoutConnecting() throws {
        let id = UUID()
        try withService(rememberedID: id, rememberedName: "ANT battery") { service, _, _, _ in
            XCTAssertEqual(service.rememberedDeviceID, id)
            XCTAssertEqual(service.rememberedDeviceName, "ANT battery")
            XCTAssertFalse(service.isForeground)
            XCTAssertFalse(service.isConnectionActive)
            XCTAssertEqual(service.state, .idle)
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
        }
    }

    @MainActor
    func testInvalidUUIDDoesNotExposeOrConnectOrphanedName() throws {
        try withService(defaultsSetup: { defaults in
            defaults.set("invalid", forKey: BmsBluetoothService.rememberedDeviceDefaultsKey)
            defaults.set("ANT orphan", forKey: BmsBluetoothService.rememberedDeviceNameDefaultsKey)
        }) { service, _, _, _ in
            XCTAssertNil(service.rememberedDeviceID)
            XCTAssertNil(service.rememberedDeviceName)
            service.beginForegroundSession()
            service.reconnectRememberedDevice()
            XCTAssertFalse(service.isConnectionActive)
            XCTAssertNotNil(service.lastError)
        }
    }

    @MainActor
    func testLegacyFilterMigratesOnlyToBatteryKeyAndNeverOverwritesNewPreference() throws {
        let legacyKey = "com.zjsf.anturide.deviceKeywordFilterEnabled"
        let controllerKey = "com.zjsf.anturide.controller.nameFilterEnabled"
        try withService(defaultsSetup: { defaults in
            defaults.set(false, forKey: legacyKey)
            defaults.set(true, forKey: controllerKey)
        }) { service, defaults, _, _ in
            XCTAssertFalse(service.isKeywordFilterEnabled)
            XCTAssertEqual(defaults.object(forKey: BmsBluetoothService.keywordFilterDefaultsKey) as? Bool, false)
            service.setKeywordFilterEnabled(true)
            XCTAssertTrue(defaults.bool(forKey: BmsBluetoothService.keywordFilterDefaultsKey))
            XCTAssertFalse(defaults.bool(forKey: legacyKey))
            XCTAssertTrue(defaults.bool(forKey: controllerKey))
            let restored = makeService(defaults: defaults)
            XCTAssertTrue(restored.isKeywordFilterEnabled)
        }
        try withService(defaultsSetup: { defaults in
            defaults.set(false, forKey: legacyKey)
            defaults.set(true, forKey: BmsBluetoothService.keywordFilterDefaultsKey)
        }) { service, _, _, _ in
            XCTAssertTrue(service.isKeywordFilterEnabled)
        }
    }

    @MainActor
    func testBatteryFilterRejectsAPTAndFFE0BypassButCanBeDisabled() throws {
        try withService { service, _, _, _ in
            XCTAssertTrue(service.isCandidate(advertisedServices: [], name: "  AnT battery  "))
            XCTAssertFalse(service.isCandidate(advertisedServices: [BmsBluetoothService.bmsServiceUUID], name: "APT controller"))
            XCTAssertFalse(service.isCandidate(advertisedServices: [BmsBluetoothService.bmsServiceUUID], name: "Unknown"))
            XCTAssertFalse(service.isCandidate(advertisedServices: [], name: ""))
            service.setKeywordFilterEnabled(false)
            XCTAssertTrue(service.isCandidate(advertisedServices: [], name: "APT controller"))
            XCTAssertTrue(service.isCandidate(advertisedServices: [], name: ""))
        }
    }

    @MainActor
    func testDirectedSearchUsesOnlyRememberedUUIDEvenWhenNameChanges() throws {
        let id = UUID()
        try withService(rememberedID: id, rememberedName: "ANT twin") { service, _, registry, _ in
            service.beginForegroundSession()
            service.beginConnectionAttempt(searchTargetID: id)
            XCTAssertTrue(service.isConnectionActive)
            XCTAssertTrue(service.matchesDiscoveredDevice(deviceID: id, name: "ANT twin"))
            XCTAssertFalse(service.matchesDiscoveredDevice(deviceID: UUID(), name: "ANT twin"))
            XCTAssertTrue(service.matchesDiscoveredDevice(deviceID: id, name: "APT renamed controller"))
            XCTAssertTrue(service.matchesDiscoveredDevice(deviceID: id, name: "unknown renamed battery"))
            service.setKeywordFilterEnabled(false)
            XCTAssertFalse(service.matchesDiscoveredDevice(deviceID: UUID(), name: "ANT twin"))
            XCTAssertTrue(registry.claim(id, for: .controller))
            XCTAssertFalse(service.matchesDiscoveredDevice(deviceID: id, name: "ANT twin"))
        }
    }

    @MainActor
    func testStopManualScanNeverCancelsAutomaticUUIDSearchOrDeadline() throws {
        let id = UUID()
        try withService(rememberedID: id) { service, _, _, _ in
            service.beginForegroundSession()
            service.beginConnectionAttempt(searchTargetID: id)
            let generation = service.connectionAttemptGeneration
            let deadline = service.connectionDeadline
            service.stopManualScan()
            XCTAssertEqual(service.automaticSearchTargetID, id)
            XCTAssertEqual(service.connectionAttemptGeneration, generation)
            XCTAssertEqual(service.connectionDeadline, deadline)
            XCTAssertTrue(service.isConnectionActive)
        }
    }

    @MainActor
    func testRepeatedActiveDoesNotResetButBackgroundToActiveDoes() throws {
        let id = UUID()
        try withService(rememberedID: id) { service, _, _, _ in
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
            service.beginForegroundSession()
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.pauseForBackground()
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
        }
    }

    @MainActor
    func testManualDisconnectSuppressesRunButNewServiceStillRemembers() throws {
        let id = UUID()
        try withService(rememberedID: id, rememberedName: "ANT") { service, defaults, _, _ in
            service.beginForegroundSession()
            service.disconnect()
            service.pauseForBackground()
            service.beginForegroundSession()
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            XCTAssertEqual(service.rememberedDeviceID, id)
            let restarted = makeService(defaults: defaults)
            restarted.beginForegroundSession()
            XCTAssertEqual(restarted.consumeAutomaticTarget(poweredOn: true), id)
        }
    }

    @MainActor
    func testExplicitRememberedRetryClearsRunSuppressionWithoutExtraSameSessionAttempt() throws {
        let id = UUID()
        try withService(rememberedID: id) { service, _, _, _ in
            service.beginForegroundSession()
            service.disconnect()
            service.reconnectRememberedDevice()
            XCTAssertNotNil(service.lastError, "无 manager 的手动重试不能假装已连接")
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.pauseForBackground()
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
        }
    }

    @MainActor
    func testManualSearchSuppressesOnlyThisForegroundAndCancelsAutoDeadline() throws {
        let id = UUID()
        try withService(rememberedID: id) { service, _, _, clock in
            service.beginForegroundSession()
            service.beginConnectionAttempt(searchTargetID: id)
            let generation = service.connectionAttemptGeneration
            service.startScan()
            XCTAssertNil(service.connectionDeadline)
            XCTAssertNil(service.automaticSearchTargetID)
            clock.advance(20)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: generation))
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.pauseForBackground()
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
        }
    }

    @MainActor
    func testManualConnectCancelsSearchAndAllowsFutureForegroundAfterDisconnect() throws {
        let id = UUID()
        try withService(rememberedID: id) { service, _, _, _ in
            service.beginForegroundSession()
            service.disconnect()
            service.beginConnectionAttempt(searchTargetID: id)
            service.connect(to: UUID())
            XCTAssertNil(service.automaticSearchTargetID)
            XCTAssertNil(service.connectionDeadline)
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.pauseForBackground()
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
        }
    }

    @MainActor
    func testDisabledSettingNeverCreatesAnAutomaticOpportunityMidSession() throws {
        let id = UUID()
        try withService(rememberedID: id, automaticEnabled: false) { service, _, _, _ in
            service.beginForegroundSession()
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            var settings = DrivingSettings()
            settings.bmsAutoConnectEnabled = true
            service.applyDrivingSettings(settings)
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            service.pauseForBackground()
            service.beginForegroundSession()
            XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
            service.beginConnectionAttempt(searchTargetID: id)
            settings.bmsAutoConnectEnabled = false
            service.applyDrivingSettings(settings)
            XCTAssertNil(service.connectionDeadline)
            XCTAssertFalse(service.isConnectionActive)
        }
    }

    @MainActor
    func testNotifyAndInvalidANTFramesCannotReplaceMemoryOrClaimRealtimeData() throws {
        let previous = UUID(), id = UUID()
        try withService(rememberedID: previous, rememberedName: "ANT previous") { service, defaults, _, _ in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT new"))
            let generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            XCTAssertEqual(service.state, .ready)
            XCTAssertNil(service.latestSnapshot)
            XCTAssertEqual(service.rememberedDeviceID, previous)
            service.receiveNotification(Data([0x7E, 0xA1, 0x01, 0, 0, 0xBE, 0x18, 0x55, 0xAA, 0x55]), deviceID: id, generation: generation)
            var invalid = validFrame()
            invalid[9] = 65
            service.receiveNotification(invalid, deviceID: id, generation: generation)
            XCTAssertNil(service.latestSnapshot)
            XCTAssertTrue(service.snapshotHistory.isEmpty)
            XCTAssertEqual(service.rememberedDeviceID, previous)
            XCTAssertEqual(service.rememberedDeviceName, "ANT previous")
            XCTAssertEqual(defaults.string(forKey: BmsBluetoothService.rememberedDeviceDefaultsKey), previous.uuidString)
        }
    }

    @MainActor
    func testFirstValidANTFrameCommitsUUIDAndNameAndCancelsDeadline() throws {
        let id = UUID()
        try withService { service, defaults, _, clock in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT tested"))
            service.beginConnectionAttempt(searchTargetID: id)
            let attempt = service.connectionAttemptGeneration
            let generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            XCTAssertNotNil(service.connectionDeadline, "Notify 不完成协议验证")
            let frame = validFrame()
            service.receiveNotification(Data(frame.prefix(55)), deviceID: id, generation: generation)
            XCTAssertNil(service.rememberedDeviceID)
            service.receiveNotification(Data(frame.dropFirst(55)), deviceID: id, generation: generation)
            XCTAssertNotNil(service.latestSnapshot)
            XCTAssertEqual(service.snapshotHistory.count, 1)
            XCTAssertEqual(service.rememberedDeviceID, id)
            XCTAssertEqual(service.rememberedDeviceName, "ANT tested")
            XCTAssertEqual(defaults.string(forKey: BmsBluetoothService.rememberedDeviceDefaultsKey), id.uuidString)
            XCTAssertEqual(defaults.string(forKey: BmsBluetoothService.rememberedDeviceNameDefaultsKey), "ANT tested")
            XCTAssertNil(service.connectionDeadline)
            clock.advance(20)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: attempt))
            XCTAssertEqual(service.state, .ready)
            let restored = makeService(defaults: defaults)
            XCTAssertEqual(restored.rememberedDeviceID, id)
            XCTAssertEqual(restored.rememberedDeviceName, "ANT tested")
        }
    }

    @MainActor
    func testSameUUIDCannotBeUsedByControllerOrReusedBeforeRetirementCallback() throws {
        let id = UUID()
        try withService { service, _, registry, _ in
            service.beginForegroundSession()
            XCTAssertTrue(registry.claim(id, for: .controller))
            XCTAssertFalse(service.prepareSession(deviceID: id, name: "ANT"))
            XCTAssertEqual(registry.owner(of: id), .controller)
            registry.release(id, for: .controller)
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            XCTAssertEqual(registry.owner(of: id), .battery)
            service.disconnect()
            XCTAssertEqual(registry.owner(of: id), .battery, "请求 cancel 不等于真正终止")
            XCTAssertFalse(registry.claim(id, for: .controller))
            XCTAssertFalse(service.prepareSession(deviceID: id, name: "ANT"))
            XCTAssertTrue(service.completeRetirement(deviceID: id))
            XCTAssertNil(registry.owner(of: id))
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            XCTAssertFalse(service.completeRetirement(deviceID: id), "重复旧终止回调不能释放新连接")
            XCTAssertEqual(registry.owner(of: id), .battery)
        }
    }

    @MainActor
    func testRetiredDifferentUUIDCallbackDoesNotClearNewSessionOrItsRegistryClaim() throws {
        let oldID = UUID(), newID = UUID()
        try withService { service, _, registry, _ in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: oldID, name: "ANT old"))
            service.disconnect()
            XCTAssertTrue(service.prepareSession(deviceID: newID, name: "ANT new"))
            let generation = service.sessionGeneration
            XCTAssertTrue(service.completeRetirement(deviceID: oldID))
            XCTAssertEqual(service.connectedDeviceID, newID)
            XCTAssertEqual(service.sessionGeneration, generation)
            XCTAssertEqual(registry.owner(of: newID), .battery)
            XCTAssertNil(registry.owner(of: oldID))
        }
    }

    @MainActor
    func testOldGenerationWrongUUIDAndPartialAssemblerCannotPolluteReplacementSession() throws {
        let id = UUID()
        try withService { service, _, _, _ in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT old"))
            let oldGeneration = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: oldGeneration)
            let frame = validFrame()
            service.receiveNotification(Data(frame.prefix(60)), deviceID: id, generation: oldGeneration)
            service.disconnect()
            XCTAssertTrue(service.completeRetirement(deviceID: id))
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT new"))
            let generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: oldGeneration)
            XCTAssertEqual(service.state, .connecting)
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            service.receiveNotification(frame, deviceID: id, generation: oldGeneration)
            service.receiveNotification(frame, deviceID: UUID(), generation: generation)
            service.receiveNotification(Data(frame.dropFirst(60)), deviceID: id, generation: generation)
            XCTAssertNil(service.latestSnapshot)
            XCTAssertNil(service.rememberedDeviceID)
            XCTAssertFalse(service.connectionDidTerminate(deviceID: id, generation: oldGeneration, error: "stale"))
            service.receiveNotification(frame, deviceID: id, generation: generation)
            XCTAssertEqual(service.snapshotHistory.count, 1)
            XCTAssertEqual(service.rememberedDeviceName, "ANT new")
        }
    }

    @MainActor
    func testMonotonicDeadlineExpiresOnceAndRetainsClaimUntilRealExit() throws {
        let id = UUID()
        try withService { service, _, registry, clock in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            service.beginConnectionAttempt(searchTargetID: id)
            let generation = service.connectionAttemptGeneration
            XCTAssertEqual(service.connectionDeadline, clock.uptime + BmsBluetoothService.connectionTimeout)
            clock.advance(9.9)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: generation))
            clock.advance(0.2)
            XCTAssertTrue(service.expireConnectionAttemptIfNeeded(generation: generation))
            XCTAssertEqual(service.state, .disconnected)
            XCTAssertFalse(service.isConnectionActive)
            XCTAssertNil(service.connectionDeadline)
            XCTAssertNil(service.automaticSearchTargetID)
            XCTAssertNotNil(service.lastError)
            XCTAssertNil(service.rememberedDeviceID)
            XCTAssertEqual(registry.owner(of: id), .battery)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: generation))
            XCTAssertTrue(service.completeRetirement(deviceID: id))
            XCTAssertNil(registry.owner(of: id))
        }
    }

    @MainActor
    func testReplacedAndCancelledDeadlineCannotTerminateNewAttempt() throws {
        try withService { service, _, _, clock in
            service.beginForegroundSession()
            service.beginConnectionAttempt(searchTargetID: UUID())
            let oldGeneration = service.connectionAttemptGeneration
            clock.advance(9)
            service.beginConnectionAttempt(searchTargetID: UUID())
            let generation = service.connectionAttemptGeneration
            clock.advance(2)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: oldGeneration))
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: generation))
            service.disconnect()
            clock.advance(20)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: generation))
            XCTAssertNil(service.connectionDeadline)
        }
    }

    @MainActor
    func testBackgroundPreservesReadyConnectionButStopsDeadlineAndRejectsSamples() throws {
        let id = UUID()
        try withService { service, _, registry, clock in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            let generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            service.receiveNotification(validFrame(), deviceID: id, generation: generation)
            let previousSnapshot = service.latestSnapshot
            service.beginConnectionAttempt(searchTargetID: id)
            let attempt = service.connectionAttemptGeneration
            let queryGeneration = service.queryGeneration
            service.pauseForBackground()
            XCTAssertFalse(service.isForeground)
            XCTAssertEqual(service.state, .ready)
            XCTAssertEqual(service.connectedDeviceID, id)
            XCTAssertEqual(registry.owner(of: id), .battery)
            XCTAssertGreaterThan(service.queryGeneration, queryGeneration)
            XCTAssertNil(service.connectionDeadline)
            service.receiveNotification(validFrame(), deviceID: id, generation: generation)
            XCTAssertEqual(service.latestSnapshot, previousSnapshot, "后台通知不得更新已验证的旧快照")
            clock.advance(20)
            XCTAssertFalse(service.expireConnectionAttemptIfNeeded(generation: attempt))
            let pausedQueryGeneration = service.queryGeneration
            service.beginForegroundSession()
            XCTAssertGreaterThan(service.queryGeneration, pausedQueryGeneration)
            service.receiveNotification(validFrame(), deviceID: id, generation: generation)
            XCTAssertNotNil(service.latestSnapshot)
        }
    }

    @MainActor
    func testBackgroundAbandonsNotifyReadyButStillUnverifiedDevice() throws {
        let id = UUID()
        try withService { service, _, registry, _ in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            let generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            XCTAssertEqual(service.state, .ready)
            XCTAssertNil(service.latestSnapshot)
            service.pauseForBackground()
            XCTAssertEqual(service.state, .disconnected)
            XCTAssertNil(service.connectedDeviceID)
            XCTAssertNil(service.rememberedDeviceID)
            XCTAssertTrue(service.completeRetirement(deviceID: id))
            XCTAssertNil(registry.owner(of: id))
        }
    }

    @MainActor
    func testBackgroundAbandonsIncompleteHandshakeAndRejectsLateNotify() throws {
        let id = UUID()
        try withService { service, _, registry, _ in
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            let generation = service.sessionGeneration
            service.beginConnectionAttempt(searchTargetID: id)
            service.pauseForBackground()
            XCTAssertEqual(service.state, .disconnected)
            XCTAssertNil(service.connectedDeviceID)
            XCTAssertNil(service.connectionDeadline)
            XCTAssertEqual(registry.owner(of: id), .battery)
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            XCTAssertEqual(service.state, .disconnected)
            XCTAssertTrue(service.completeRetirement(deviceID: id))
            XCTAssertNil(registry.owner(of: id))
        }
    }

    @MainActor
    func testTerminalCallbackClearsSessionAndPowerOffReleasesActiveAndRetiringOnly() throws {
        let id = UUID(), oldID = UUID(), controllerID = UUID()
        try withService { service, _, registry, _ in
            service.beginForegroundSession()
            XCTAssertTrue(registry.claim(controllerID, for: .controller))
            XCTAssertTrue(service.prepareSession(deviceID: oldID, name: "ANT old"))
            service.disconnect()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            var generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            service.receiveNotification(validFrame(), deviceID: id, generation: generation)
            XCTAssertTrue(service.connectionDidTerminate(deviceID: id, generation: generation, error: "failed"))
            XCTAssertNil(service.connectedDeviceID)
            XCTAssertNil(service.connectedDeviceName)
            XCTAssertNil(service.latestSnapshot)
            XCTAssertTrue(service.snapshotHistory.isEmpty)
            XCTAssertNil(registry.owner(of: id))
            XCTAssertEqual(service.lastError, "failed")
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            generation = service.sessionGeneration
            service.bluetoothDidPowerOff()
            XCTAssertEqual(service.state, .poweredOff)
            XCTAssertNil(registry.owner(of: id))
            XCTAssertNil(registry.owner(of: oldID))
            XCTAssertEqual(registry.owner(of: controllerID), .controller)
            XCTAssertFalse(service.connectionDidTerminate(deviceID: id, generation: generation, error: "late"))
            XCTAssertEqual(service.rememberedDeviceID, id, "掉电不等于忘记设备")
        }
    }

    @MainActor
    func testForgetDeletesOnlyBMSMemoryAndLateCallbacksCannotRestoreIt() throws {
        let id = UUID()
        try withService(rememberedID: id, rememberedName: "ANT") { service, defaults, registry, _ in
            defaults.set("controller-sentinel", forKey: "com.zjsf.anturide.controller.lastPeripheralUUID")
            defaults.set(Data([1, 2, 3]), forKey: "history-sentinel")
            service.beginForegroundSession()
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "ANT"))
            let generation = service.sessionGeneration
            service.notificationsDidBecomeReady(deviceID: id, generation: generation)
            service.forgetDevice()
            XCTAssertNil(service.rememberedDeviceID)
            XCTAssertNil(service.rememberedDeviceName)
            XCTAssertNil(defaults.object(forKey: BmsBluetoothService.rememberedDeviceDefaultsKey))
            XCTAssertNil(defaults.object(forKey: BmsBluetoothService.rememberedDeviceNameDefaultsKey))
            XCTAssertEqual(defaults.string(forKey: "com.zjsf.anturide.controller.lastPeripheralUUID"), "controller-sentinel")
            XCTAssertEqual(defaults.data(forKey: "history-sentinel"), Data([1, 2, 3]))
            XCTAssertEqual(registry.owner(of: id), .battery)
            service.receiveNotification(validFrame(), deviceID: id, generation: generation)
            XCTAssertNil(service.rememberedDeviceID)
            XCTAssertNil(service.latestSnapshot)
            XCTAssertTrue(service.completeRetirement(deviceID: id))
            service.pauseForBackground()
            service.beginForegroundSession()
            XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
            let restored = makeService(defaults: defaults)
            XCTAssertNil(restored.rememberedDeviceID)
            XCTAssertNil(restored.rememberedDeviceName)
        }
    }

    private func validFrame() -> Data {
        var bytes = [UInt8](repeating: 0, count: 180)
        bytes[0] = 0x7E; bytes[1] = 0xA1; bytes[2] = 0x11
        bytes[5] = 172; bytes[7] = 1; bytes[8] = 2; bytes[9] = 20
        for cell in 0..<20 {
            let millivolts = UInt16(3500 + cell)
            bytes[34 + cell * 2] = UInt8(millivolts & 0xFF)
            bytes[35 + cell * 2] = UInt8(millivolts >> 8)
        }
        bytes[74] = 25; bytes[76] = 26; bytes[86] = 80
        bytes[178] = 0xAA; bytes[179] = 0x55
        return Data(bytes)
    }

    @MainActor
    private func makeService(defaults: UserDefaults) -> BmsBluetoothService {
        BmsBluetoothService(defaults: defaults, startupAutoConnectEnabled: true, queryIntervalMs: 1000,
                            createsBluetoothManager: false, registry: BluetoothDeviceRegistry())
    }

    @MainActor private final class Clock {
        var uptime: TimeInterval = 100
        func advance(_ seconds: TimeInterval) { uptime += seconds }
    }

    @MainActor
    private func withService(rememberedID: UUID? = nil, rememberedName: String? = nil,
                             automaticEnabled: Bool = true,
                             defaultsSetup: (UserDefaults) -> Void = { _ in },
                             _ body: (BmsBluetoothService, UserDefaults, BluetoothDeviceRegistry, Clock) -> Void) throws {
        let suite = "BmsBluetoothServiceTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let rememberedID { defaults.set(rememberedID.uuidString, forKey: BmsBluetoothService.rememberedDeviceDefaultsKey) }
        if let rememberedName { defaults.set(rememberedName, forKey: BmsBluetoothService.rememberedDeviceNameDefaultsKey) }
        defaultsSetup(defaults)
        let registry = BluetoothDeviceRegistry()
        let clock = Clock()
        let service = BmsBluetoothService(defaults: defaults, startupAutoConnectEnabled: automaticEnabled,
                                          queryIntervalMs: 1000, createsBluetoothManager: false,
                                          registry: registry, uptime: { clock.uptime })
        defer {
            service.bluetoothDidPowerOff()
            defaults.removePersistentDomain(forName: suite)
        }
        body(service, defaults, registry, clock)
    }
}
