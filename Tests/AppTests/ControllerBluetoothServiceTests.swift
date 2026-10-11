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

    @MainActor private func withService(_ body: (ControllerBluetoothService, Clock) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ControllerBluetoothTests-\(UUID())")
        let clock = Clock()
        let service = ControllerBluetoothService(historyStore: ControllerHistoryStore(directory: directory),
                                                clock: { clock.date }, uptime: { clock.monotonic }, createsBluetoothManager: false)
        defer {
            service.disconnect()
            if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
        }
        try body(service, clock)
    }
}
