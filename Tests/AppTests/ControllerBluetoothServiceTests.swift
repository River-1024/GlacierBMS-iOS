import ANTuRideDomain
import Combine
import CoreBluetooth
import Foundation
import XCTest
@testable import ANTuRide

/// 仅验证会话核心与真实 Domain 协议；不把注入事件当成 BLE/权限/真机验收。
final class ControllerBluetoothServiceTests: XCTestCase {
    @MainActor
    func testAndroidServiceOrderPropertyContractAndOnlyQueryGolden() throws {
        XCTAssertEqual(ControllerBluetoothService.queryInterval, 0.05)
        XCTAssertEqual(ControllerBluetoothService.serviceUUIDs, [CBUUID(string: "FFE0"), CBUUID(string: "FF00")])
        XCTAssertTrue(ControllerBluetoothService.supportsControllerProperties([.write, .notify]))
        XCTAssertTrue(ControllerBluetoothService.supportsControllerProperties([.write, .indicate]))
        XCTAssertFalse(ControllerBluetoothService.supportsControllerProperties([.writeWithoutResponse, .notify]))
        XCTAssertFalse(ControllerBluetoothService.supportsControllerProperties([.write]))
        XCTAssertFalse(ControllerBluetoothService.supportsControllerProperties([.notify]))
        try withService { service, _ in
            service.setPollingEnabled(true)
            service.prepareSession(deviceID: UUID(), name: "APT")
            XCTAssertNil(service.nextQuery())
            service.notificationsDidBecomeReady()
            XCTAssertEqual(service.nextQuery(), Data([0xA8, 0x02, 0x01, 0x24, 0x01, 0x1F, 0x3E, 0x4F]))
            XCTAssertNil(service.nextQuery())
            service.queryWriteDidComplete()
            XCTAssertNil(service.nextQuery(), "写入确认不是完整响应，不能提前放行")
        }
    }

    @MainActor
    func testAtomicSnapshotPublishesAfterWholeFrameAndClearsOnGlobalBackground() throws {
        try withService { service, clock in
            ready(service)
            var events: [ControllerTelemetrySnapshot?] = []
            let subscription = service.$latestSnapshot.sink { events.append($0) }
            defer { subscription.cancel() }
            XCTAssertEqual(events.count, 1) // @Published 订阅时的初始 nil。
            _ = service.nextQuery()
            service.queryWriteDidComplete()
            service.receiveNotification(Data(response().prefix(20)))
            XCTAssertEqual(events.count, 1)
            service.receiveNotification(Data(response().dropFirst(20)))
            XCTAssertEqual(events.count, 2)
            let snapshot = try XCTUnwrap(events.last.flatMap { $0 })
            XCTAssertEqual(snapshot.receivedAt, clock.date)
            XCTAssertEqual(snapshot.telemetry.rpm, 1250)
            XCTAssertEqual(service.latestTelemetry, snapshot.telemetry)
            XCTAssertEqual(service.lastValidAt, snapshot.receivedAt)
            service.setPollingEnabled(false)
            XCTAssertEqual(events.count, 3)
            XCTAssertNil(events.last.flatMap { $0 })
            XCTAssertNil(service.latestSnapshot)
        }
    }

    @MainActor
    func testGlobalForegroundOwnerMustExplicitlyEnablePolling() throws {
        try withService { service, _ in
            service.prepareSession(deviceID: UUID(), name: "APT")
            service.notificationsDidBecomeReady()
            XCTAssertEqual(service.state, .paused)
            XCTAssertNil(service.nextQuery())
            service.setPollingEnabled(true)
            XCTAssertEqual(service.state, .ready)
            XCTAssertNotNil(service.nextQuery())
        }
    }

    @MainActor
    func testEveryFragmentBoundaryDisplaysOnlyAfterWhole37Or39ByteFrame() throws {
        try withService { service, _ in
            for length in [0x1D, 0x1F] {
                let bytes = response(length: length)
                for split in 1..<bytes.count {
                    ready(service)
                    XCTAssertNotNil(service.nextQuery())
                    service.queryWriteDidComplete()
                    service.receiveNotification(Data(bytes.prefix(split)))
                    XCTAssertNil(service.latestTelemetry)
                    XCTAssertEqual(service.pendingByteCount, split)
                    XCTAssertNil(service.nextQuery())
                    service.receiveNotification(Data(bytes.dropFirst(split)))
                    let telemetry = try XCTUnwrap(service.latestTelemetry)
                    XCTAssertEqual(telemetry.controllerVoltageV, 72.3, accuracy: 1e-9)
                    XCTAssertEqual(telemetry.busCurrentA, -12.5, accuracy: 1e-9)
                    XCTAssertEqual(telemetry.rpm, 1250)
                    XCTAssertEqual(telemetry.linearBrakeVoltageV, length == 0x1D ? nil : 0.4)
                    XCTAssertEqual(service.frameCount, 1)
                    XCTAssertEqual(service.pendingByteCount, 0)
                }
            }
        }
    }

    @MainActor
    func testResponseTimeoutFlushesHalfFrameAndDoesNotAcceptLateTail() throws {
        try withService { service, clock in
            ready(service)
            _ = service.nextQuery()
            service.queryWriteDidComplete()
            service.receiveNotification(Data(response().prefix(20)))
            clock.advance(ControllerBluetoothService.responseTimeout)
            service.tick()
            XCTAssertNil(service.latestTelemetry)
            XCTAssertEqual(service.pendingByteCount, 0)
            XCTAssertNotNil(service.lastError)
            service.receiveNotification(Data(response().dropFirst(20)))
            XCTAssertNil(service.latestTelemetry)
            XCTAssertEqual(service.pendingByteCount, 0)
            _ = service.nextQuery()
            service.queryWriteDidComplete()
            service.receiveNotification(response())
            XCTAssertNotNil(service.latestTelemetry)
            XCTAssertNil(service.lastError)
        }
    }

    @MainActor
    func testWriteAcknowledgementMissingAfterResponseStillTimesOutInsteadOfDeadlocking() throws {
        try withService { service, clock in
            ready(service)
            _ = service.nextQuery()
            service.receiveNotification(response())
            XCTAssertNotNil(service.latestTelemetry)
            XCTAssertNil(service.nextQuery())
            clock.advance(ControllerBluetoothService.responseTimeout)
            service.tick()
            XCTAssertEqual(service.state, .failed)
            XCTAssertNil(service.latestTelemetry)
            XCTAssertNil(service.connectedDeviceID)
        }
    }

    @MainActor
    func testInvalidWholeFrameDoesNotRefreshOrRecordButReleasesQuery() throws {
        try withService { service, clock in
            ready(service)
            receive(service)
            let validAt = service.lastValidAt
            XCTAssertTrue(service.startRecording())
            _ = service.nextQuery()
            service.queryWriteDidComplete()
            service.receiveNotification(response(length: 3))
            XCTAssertEqual(service.lastValidAt, validAt)
            XCTAssertNotNil(service.latestTelemetry)
            XCTAssertNotNil(service.lastError)
            XCTAssertEqual(service.recordedSampleCount, 0)
            XCTAssertNotNil(service.nextQuery())
            service.queryWriteDidComplete()
            clock.advance(ControllerBluetoothService.responseTimeout)
            service.tick()
            XCTAssertNil(service.latestTelemetry)
            service.stopRecording()
            XCTAssertEqual(service.historyRecords.first?.samples.count, 0)
        }
    }

    @MainActor
    func testRecordingCapturesOnlyNewFramesAndPersistsMissingSpeedAndShortBrake() throws {
        try withService { service, clock in
            ready(service)
            receive(service)
            XCTAssertTrue(service.startRecording())
            XCTAssertFalse(service.startRecording())
            XCTAssertEqual(service.recordedSampleCount, 0)
            clock.advance(0.05)
            receive(service, length: 0x1D)
            clock.advance(0.05)
            receive(service)
            service.stopRecording()
            service.stopRecording()
            XCTAssertFalse(service.isRecording)
            XCTAssertNil(service.pendingRecord)
            XCTAssertEqual(service.historyRecords.count, 1)
            let record = try XCTUnwrap(service.historyRecords.first)
            XCTAssertEqual(record.samples.count, 2)
            XCTAssertTrue(record.samples.allSatisfy { $0.speed.isNaN })
            XCTAssertTrue(record.samples[0].brake.isNaN)
            XCTAssertEqual(record.samples[1].brake, 0.4, accuracy: 1e-9)
            XCTAssertEqual(record.samples[0].rpm, 1250)
            XCTAssertNil(service.historyError)
        }
    }

    @MainActor
    func testMultipleFramesWithIdenticalReceiptTimeSkipAmbiguousRowsWithoutInventingTime() throws {
        try withService { service, _ in
            ready(service)
            receive(service)
            XCTAssertTrue(service.startRecording())
            _ = service.nextQuery()
            service.queryWriteDidComplete()
            service.receiveNotification(response() + response())
            XCTAssertEqual(service.recordedSampleCount, 1)
            XCTAssertNotNil(service.recordingTimingWarning)
            service.stopRecording()
            let samples = try XCTUnwrap(service.historyRecords.first?.samples)
            XCTAssertEqual(samples.count, 1)
            XCTAssertEqual(samples[0].timestamp, service.historyRecords.first?.startedAt)
            XCTAssertNotNil(service.historyRecords.first?.timingWarning)
        }
    }

    @MainActor
    func testGlobalForegroundPauseAndDisconnectClearValuesSaveRecordingAndDropFurtherNotifications() throws {
        try withService { service, clock in
            ready(service)
            receive(service)
            XCTAssertTrue(service.startRecording())
            clock.advance(0.05)
            receive(service)
            service.setPollingEnabled(false)
            XCTAssertEqual(service.state, .paused)
            XCTAssertNil(service.latestTelemetry)
            XCTAssertNil(service.lastValidAt)
            XCTAssertFalse(service.isRecording)
            XCTAssertEqual(service.historyRecords.count, 1)
            XCTAssertNil(service.nextQuery())
            service.receiveNotification(response())
            XCTAssertNil(service.latestTelemetry)
            service.setPollingEnabled(true)
            XCTAssertEqual(service.state, .ready)
            XCTAssertNil(service.latestTelemetry)
            receive(service)
            XCTAssertNotNil(service.latestTelemetry)
            XCTAssertTrue(service.startRecording())
            clock.advance(0.05)
            receive(service)
            service.disconnect()
            XCTAssertNil(service.latestTelemetry)
            XCTAssertNil(service.connectedDeviceID)
            XCTAssertFalse(service.isRecording)
            XCTAssertEqual(service.historyRecords.count, 2)
            XCTAssertNil(service.nextQuery())
        }
    }

    @MainActor
    func testRecordingDurationUsesMonotonicTimeAndAutoSaves() throws {
        try withService { service, clock in
            ready(service)
            receive(service)
            XCTAssertTrue(service.startRecording())
            clock.advance(0.05)
            receive(service)
            clock.monotonic += ControllerBluetoothService.recordingDuration
            service.tick()
            XCTAssertFalse(service.isRecording)
            XCTAssertEqual(service.recordingSecondsRemaining, 0)
            XCTAssertEqual(service.historyRecords.first?.samples.count, 1)
            XCTAssertNil(service.pendingRecord)
        }
    }

    @MainActor
    func testSaveFailureRetainsPendingSnapshotAndRetryDoesNotLoseSamples() throws {
        try withService { service, clock in
            let directory = service.historyStore.directory
            try Data("blocked".utf8).write(to: directory)
            ready(service)
            receive(service)
            XCTAssertTrue(service.startRecording())
            clock.advance(0.05)
            receive(service)
            service.stopRecording()
            XCTAssertNotNil(service.pendingRecord)
            XCTAssertNotNil(service.historyError)
            XCTAssertFalse(service.startRecording())
            let id = try XCTUnwrap(service.pendingRecord?.id)
            try FileManager.default.removeItem(at: directory)
            service.savePendingRecord()
            XCTAssertNil(service.pendingRecord)
            XCTAssertNil(service.historyError)
            XCTAssertEqual(service.historyRecords.map(\.id), [id])
            XCTAssertEqual(service.historyRecords.first?.samples.count, 1)
            service.deleteRecord(id: id)
            XCTAssertTrue(service.historyRecords.isEmpty)
        }
    }

    @MainActor
    func testConnectionTimeoutAndWriteFailureEndSession() throws {
        try withService { service, clock in
            service.prepareSession(deviceID: UUID(), name: "APT")
            clock.advance(15)
            service.tick()
            XCTAssertEqual(service.state, .failed)
            XCTAssertNil(service.connectedDeviceID)
            ready(service)
            _ = service.nextQuery()
            service.queryWriteDidComplete(error: NSError(domain: "test", code: 1))
            XCTAssertEqual(service.state, .failed)
            XCTAssertNil(service.nextQuery())
        }
    }

    @MainActor
    func testPublicInitializerSupportsNoBluetoothManagerAndFreshRegistry() throws {
        try withDefaults { defaults in
            let service = ControllerBluetoothService(defaults: defaults, createsBluetoothManager: false,
                                                     registry: BluetoothDeviceRegistry())
            defer { service.disconnect() }
            XCTAssertTrue(service.isKeywordFilterEnabled)
            service.startScan()
            XCTAssertEqual(service.state, .idle)
            XCTAssertNotNil(service.lastError)
            XCTAssertFalse(service.isConnectionActive)
        }
    }

    @MainActor
    func testDisablingAutoPreferenceCancelsPendingAttemptWithoutChangingPollingCadence() throws {
        try withDefaults { defaults in
            let id = UUID()
            defaults.set(id.uuidString, forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey)
            try withService(defaults: defaults) { service, clock in
                service.setPollingEnabled(true)
                XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
                XCTAssertTrue(service.beginAutomaticRecovery(to: id))
                var settings = DrivingSettings()
                settings.controllerAutoConnectEnabled = false
                settings.bluetoothRefreshIntervalMs = 60_000
                service.applyDrivingSettings(settings)
                XCTAssertNil(service.automaticConnectionTargetID)
                XCTAssertFalse(service.isConnectionActive)
                clock.advance(ControllerBluetoothService.automaticConnectionTimeout)
                service.tick()
                XCTAssertEqual(service.state, .disconnected)
                service.beginForegroundSession()
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
                settings.controllerAutoConnectEnabled = true
                service.applyDrivingSettings(settings)
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true), "偏好开启不追抢本次前台机会")
                service.beginForegroundSession()
                XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
                XCTAssertEqual(ControllerBluetoothService.queryInterval, 0.05)
            }
        }
    }

    @MainActor
    func testControllerNameFilterPersistsIndependentlyOfBatteryPreference() throws {
        try withDefaults { defaults in
            let batteryKey = "com.zjsf.anturide.bms.nameFilterEnabled"
            defaults.set(false, forKey: batteryKey)
            defaults.set(false, forKey: "com.zjsf.anturide.deviceKeywordFilterEnabled")
            try withService(defaults: defaults) { service, _ in
                XCTAssertTrue(service.isKeywordFilterEnabled, "不从电池/旧全局过滤 key 继承控制器偏好")
                service.setKeywordFilterEnabled(false)
                XCTAssertFalse(defaults.bool(forKey: ControllerBluetoothService.keywordFilterDefaultsKey))
                XCTAssertFalse(defaults.bool(forKey: batteryKey))
                try withService(defaults: defaults) { reloaded, _ in
                    XCTAssertFalse(reloaded.isKeywordFilterEnabled)
                    reloaded.setKeywordFilterEnabled(true)
                }
                XCTAssertTrue(defaults.bool(forKey: ControllerBluetoothService.keywordFilterDefaultsKey))
                XCTAssertFalse(defaults.bool(forKey: batteryKey))
            }
        }
    }

    @MainActor
    func testRememberedDeviceChangesOnlyAfterFirstValidWholeControllerFrame() throws {
        try withDefaults { defaults in
            let oldID = UUID()
            defaults.set(oldID.uuidString, forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey)
            defaults.set("APT old", forKey: ControllerBluetoothService.rememberedDeviceNameDefaultsKey)
            try withService(defaults: defaults) { service, _ in
                XCTAssertEqual(service.rememberedDeviceID, oldID)
                XCTAssertEqual(service.rememberedDeviceName, "APT old")
                ready(service)
                let newID = try XCTUnwrap(service.connectedDeviceID)
                // Notify、完整无效帧和半帧都不是协议角色凭证。
                XCTAssertEqual(service.rememberedDeviceID, oldID)
                receive(service, length: 3)
                XCTAssertEqual(service.rememberedDeviceID, oldID)
                XCTAssertNotNil(service.nextQuery())
                service.queryWriteDidComplete()
                service.receiveNotification(Data(response().prefix(20)))
                XCTAssertEqual(defaults.string(forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey), oldID.uuidString)
                service.receiveNotification(Data(response().dropFirst(20)))
                XCTAssertEqual(service.rememberedDeviceID, newID)
                XCTAssertEqual(service.rememberedDeviceName, "APT")
                XCTAssertEqual(defaults.string(forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey), newID.uuidString)
                XCTAssertEqual(defaults.string(forKey: ControllerBluetoothService.rememberedDeviceNameDefaultsKey), "APT")
                service.disconnect()
                try withService(defaults: defaults) { reloaded, _ in
                    XCTAssertEqual(reloaded.rememberedDeviceID, newID)
                    XCTAssertEqual(reloaded.rememberedDeviceName, "APT")
                }
            }
        }
    }

    @MainActor
    func testForgetDisconnectsAndDeletesOnlyControllerMemory() throws {
        try withDefaults { defaults in
            let batteryKey = "com.zjsf.anturide.bms.lastPeripheralUUID"
            defaults.set("battery-memory", forKey: batteryKey)
            try withService(defaults: defaults) { service, clock in
                ready(service)
                receive(service)
                XCTAssertTrue(service.startRecording())
                clock.advance(0.05)
                receive(service)
                service.setKeywordFilterEnabled(false)
                XCTAssertTrue(service.isConnectionActive)
                service.forgetDevice()
                XCTAssertFalse(service.isConnectionActive)
                XCTAssertNil(service.latestTelemetry)
                XCTAssertFalse(service.isRecording)
                XCTAssertEqual(service.historyRecords.first?.samples.count, 1)
                XCTAssertNil(service.rememberedDeviceID)
                XCTAssertNil(service.rememberedDeviceName)
                XCTAssertNil(defaults.object(forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey))
                XCTAssertNil(defaults.object(forKey: ControllerBluetoothService.rememberedDeviceNameDefaultsKey))
                XCTAssertEqual(defaults.string(forKey: batteryKey), "battery-memory")
                XCTAssertFalse(service.isKeywordFilterEnabled)
                try withService(defaults: defaults) { reloaded, _ in
                    XCTAssertNil(reloaded.rememberedDeviceID)
                    XCTAssertNil(reloaded.rememberedDeviceName)
                    reloaded.setPollingEnabled(true)
                    XCTAssertNil(reloaded.consumeAutomaticTarget(poweredOn: true))
                }
            }
        }
    }

    @MainActor
    func testAutomaticRecoveryUsesUUIDEvenWhenRememberedDeviceIsRenamed() throws {
        try withService { service, _ in
            service.setPollingEnabled(true)
            let id = UUID()
            XCTAssertTrue(service.beginAutomaticRecovery(to: id))
            XCTAssertTrue(service.isConnectionActive)
            XCTAssertTrue(service.acceptsDiscoveredDevice(id: id, name: "APT controller"))
            XCTAssertFalse(service.acceptsDiscoveredDevice(id: UUID(), name: "APT controller"))
            XCTAssertTrue(service.acceptsDiscoveredDevice(id: id, name: "ANT renamed"))
            XCTAssertTrue(service.acceptsDiscoveredDevice(id: id, name: "FFE0 device"))
            service.setKeywordFilterEnabled(false)
            XCTAssertTrue(service.acceptsDiscoveredDevice(id: id, name: "unnamed"))
            XCTAssertFalse(service.acceptsDiscoveredDevice(id: UUID(), name: "unnamed"))
        }
    }

    @MainActor
    func testLeavingSettingsDoesNotCancelDirectedSearch() throws {
        try withService { service, _ in
            service.setPollingEnabled(true)
            let id = UUID()
            XCTAssertTrue(service.beginAutomaticRecovery(to: id))
            service.stopManualScan()
            XCTAssertEqual(service.automaticConnectionTargetID, id)
            XCTAssertEqual(service.state, .scanning)
            XCTAssertTrue(service.isConnectionActive)
        }
    }

    @MainActor
    func testManualNotifyWithoutValidFrameStillHasFiniteProtocolDeadline() throws {
        try withService { service, clock in
            service.setPollingEnabled(true)
            XCTAssertTrue(service.prepareSession(deviceID: UUID(), name: "APT"))
            service.notificationsDidBecomeReady()
            clock.advance(15)
            service.tick()
            XCTAssertEqual(service.state, .failed)
            XCTAssertNil(service.rememberedDeviceID)
        }
    }

    @MainActor
    func testAutomaticRecoveryDeadlineIsMonotonicAndFiniteAfterNotify() throws {
        try withService { service, clock in
            service.setPollingEnabled(true)
            let id = UUID()
            XCTAssertTrue(service.beginAutomaticRecovery(to: id))
            clock.date.addTimeInterval(86_400)
            service.tick()
            XCTAssertEqual(service.automaticConnectionTargetID, id)
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "APT"))
            service.notificationsDidBecomeReady()
            XCTAssertEqual(service.state, .ready)
            XCTAssertNil(service.rememberedDeviceID)
            clock.monotonic += ControllerBluetoothService.automaticConnectionTimeout
            service.tick()
            XCTAssertEqual(service.state, .failed)
            XCTAssertNil(service.automaticConnectionTargetID)
            XCTAssertFalse(service.isConnectionActive)
            XCTAssertNil(service.nextQuery())
        }
    }

    @MainActor
    func testStoppingScanDoesNotCancelAutomaticGATTHandshakeButBackgroundDoes() throws {
        try withService { service, _ in
            service.setPollingEnabled(true)
            let id = UUID()
            XCTAssertTrue(service.beginAutomaticRecovery(to: id))
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "APT"))
            service.stopScan() // 设置页离开只停止扫描，不应断开已经开始的 GATT。
            XCTAssertEqual(service.state, .connecting)
            XCTAssertEqual(service.automaticConnectionTargetID, id)
            service.setPollingEnabled(false)
            XCTAssertNil(service.automaticConnectionTargetID)
            XCTAssertFalse(service.isConnectionActive)
        }
    }

    @MainActor
    func testValidControllerFrameCompletesAutomaticAttemptAndDoesNotRetireSessionAtOldDeadline() throws {
        try withService { service, clock in
            service.setPollingEnabled(true)
            let id = UUID()
            XCTAssertTrue(service.beginAutomaticRecovery(to: id))
            XCTAssertTrue(service.prepareSession(deviceID: id, name: "APT"))
            service.notificationsDidBecomeReady()
            receive(service)
            XCTAssertNil(service.automaticConnectionTargetID)
            XCTAssertEqual(service.rememberedDeviceID, id)
            clock.advance(ControllerBluetoothService.automaticConnectionTimeout)
            service.tick()
            XCTAssertEqual(service.state, .ready)
            XCTAssertEqual(service.connectedDeviceID, id)
            XCTAssertNil(service.latestTelemetry, "旧遥测仍按现有响应时效失效")
        }
    }

    @MainActor
    func testBackgroundAndManualActionsCancelPendingAutomaticAttempt() throws {
        try withService { service, clock in
            service.setPollingEnabled(true)
            XCTAssertTrue(service.beginAutomaticRecovery(to: UUID()))
            service.setPollingEnabled(false)
            XCTAssertFalse(service.isConnectionActive)
            XCTAssertNil(service.automaticConnectionTargetID)
            XCTAssertFalse(service.beginAutomaticRecovery(to: UUID()), "自动重连只在前台")
            service.setPollingEnabled(true)
            XCTAssertTrue(service.beginAutomaticRecovery(to: UUID()))
            service.startScan() // 无硬件：仍必须先取消 auto，再报告蓝牙不可用。
            XCTAssertNil(service.automaticConnectionTargetID)
            XCTAssertTrue(service.beginAutomaticRecovery(to: UUID()))
            service.connect(to: UUID())
            XCTAssertNil(service.automaticConnectionTargetID)
            XCTAssertTrue(service.beginAutomaticRecovery(to: UUID()))
            service.disconnect()
            clock.advance(ControllerBluetoothService.automaticConnectionTimeout)
            service.tick()
            XCTAssertEqual(service.state, .disconnected, "旧 auto deadline 不得污染手动退休")
        }
    }

    @MainActor
    func testForegroundRetriesAreBoundedAndTimeoutDoesNotSuppressLaterForeground() throws {
        try withDefaults { defaults in
            let id = UUID()
            defaults.set(id.uuidString, forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey)
            try withService(defaults: defaults) { service, clock in
                service.setPollingEnabled(true)
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: false))
                XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
                XCTAssertTrue(service.beginAutomaticRecovery(to: id))
                clock.advance(ControllerBluetoothService.automaticConnectionTimeout)
                service.tick()
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
                service.setPollingEnabled(false)
                service.beginForegroundSession()
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true), "后台不消费重连机会")
                service.setPollingEnabled(true)
                XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
            }
        }
    }

    @MainActor
    func testManualDisconnectSuppressesForRunButRestartKeepsMemoryAndManualConnectClearsSuppression() throws {
        try withDefaults { defaults in
            let id = UUID()
            defaults.set(id.uuidString, forKey: ControllerBluetoothService.rememberedDeviceDefaultsKey)
            try withService(defaults: defaults) { service, _ in
                service.setPollingEnabled(true)
                service.disconnect()
                service.beginForegroundSession()
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true))
                XCTAssertEqual(service.rememberedDeviceID, id)
                try withService(defaults: defaults) { restarted, _ in
                    restarted.setPollingEnabled(true)
                    XCTAssertEqual(restarted.consumeAutomaticTarget(poweredOn: true), id)
                }
                service.reconnectRememberedDevice() // 没有 BLE manager 也应进入显式手动策略路径。
                XCTAssertNil(service.consumeAutomaticTarget(poweredOn: true), "手动操作占用本次前台机会")
                service.beginForegroundSession()
                XCTAssertEqual(service.consumeAutomaticTarget(poweredOn: true), id)
            }
        }
    }

    @MainActor
    func testRegistryRejectsBatteryUUIDAndReleasesOnlyOwnedControllerOnRetirementOrTimeout() throws {
        let registry = BluetoothDeviceRegistry()
        let batteryID = UUID()
        let otherControllerID = UUID()
        XCTAssertTrue(registry.claim(batteryID, for: .battery))
        XCTAssertTrue(registry.claim(otherControllerID, for: .controller))
        try withService(registry: registry) { service, clock in
            XCTAssertFalse(service.prepareSession(deviceID: batteryID, name: "APT"))
            XCTAssertFalse(service.isConnectionActive)
            service.disconnect()
            XCTAssertEqual(registry.owner(of: batteryID), .battery)
            service.setPollingEnabled(true)
            XCTAssertFalse(service.beginAutomaticRecovery(to: batteryID))
            let controllerID = UUID()
            XCTAssertTrue(service.beginAutomaticRecovery(to: controllerID))
            XCTAssertEqual(registry.owner(of: controllerID), .controller)
            clock.advance(ControllerBluetoothService.automaticConnectionTimeout)
            service.tick()
            XCTAssertNil(registry.owner(of: controllerID))
            XCTAssertEqual(registry.owner(of: otherControllerID), .controller)
            XCTAssertEqual(registry.owner(of: batteryID), .battery)
            XCTAssertTrue(service.prepareSession(deviceID: controllerID, name: "APT"))
            service.disconnect()
            XCTAssertNil(registry.owner(of: controllerID))
            XCTAssertEqual(registry.owner(of: otherControllerID), .controller)
        }
    }

    @MainActor private func ready(_ service: ControllerBluetoothService) {
        service.disconnect()
        service.setPollingEnabled(true)
        service.prepareSession(deviceID: UUID(), name: "APT")
        service.notificationsDidBecomeReady()
    }

    @MainActor private func receive(_ service: ControllerBluetoothService, length: Int = 0x1F) {
        XCTAssertNotNil(service.nextQuery())
        service.queryWriteDidComplete()
        service.receiveNotification(response(length: length))
    }

    private func response(length: Int = 0x1F) -> Data {
        var bytes = [UInt8](repeating: 0x0D, count: 6 + length + 2)
        bytes[3] = 0x24; bytes[4] = 0x01; bytes[5] = UInt8(length)
        func set(_ offset: Int, _ value: Int) {
            let bits = UInt16(truncatingIfNeeded: value)
            bytes[6 + offset] = UInt8(bits & 0xFF)
            bytes[7 + offset] = UInt8(bits >> 8)
        }
        if length >= 0x1D {
            set(0, 723); set(2, -125); set(4, 1250)
            if length == 0x1F { set(29, 40) }
        }
        return Data(bytes)
    }

    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var monotonic: TimeInterval = 10
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds); monotonic += seconds }
    }

    @MainActor private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ControllerBluetoothDefaults-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor private func withService(defaults injectedDefaults: UserDefaults? = nil,
                                       registry: BluetoothDeviceRegistry? = nil,
                                       _ body: (ControllerBluetoothService, Clock) throws -> Void) throws {
        let suite = "ControllerBluetoothDefaults-\(UUID())"
        let defaults = try XCTUnwrap(injectedDefaults ?? UserDefaults(suiteName: suite))
        defer { if injectedDefaults == nil { defaults.removePersistentDomain(forName: suite) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ControllerBluetoothTests-\(UUID())")
        let clock = Clock()
        let service = ControllerBluetoothService(historyStore: ControllerHistoryStore(directory: directory),
                                                clock: { clock.date }, uptime: { clock.monotonic }, createsBluetoothManager: false,
                                                defaults: defaults, registry: registry ?? BluetoothDeviceRegistry())
        defer {
            service.disconnect()
            if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
        }
        try body(service, clock)
    }
}
