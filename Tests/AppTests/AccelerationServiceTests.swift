import ANTuRideDomain
import Combine
import Foundation
import UIKit
import XCTest
@testable import ANTuRide

/// Notification fixtures exercise the real controller parser/publisher, not live BLE.
/// They are test-only inputs and never an app simulation/calibration path.
final class AccelerationServiceTests: XCTestCase {
    @MainActor
    func testRequiresReadyAndNewReceiptRatherThanPublishedInitialReplay() throws {
        try withServices { controller, service, clock, _ in
            XCTAssertFalse(service.canStart)
            XCTAssertThrowsError(try service.start())
            ready(controller)
            XCTAssertThrowsError(try service.start())
            receive(controller, rpm: 0)
            XCTAssertTrue(service.canStart)
            let lateService = AccelerationService(controller: controller,
                historyStore: service.historyStore, wallClock: { clock.date }, monotonicClock: { clock.monotonic })
            XCTAssertFalse(lateService.hasFreshSnapshot, "订阅时旧快照不算一次新接收")
            XCTAssertThrowsError(try lateService.start())
            clock.advance(0.1)
            receive(controller, rpm: 0)
            XCTAssertTrue(lateService.canStart)
        }
    }

    @MainActor
    func testUsesSnapshotEventArgumentNotPreviousWillSetProperty() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            XCTAssertTrue(try XCTUnwrap(service.record).speedSamples.isEmpty, "不得重放启动前缓存")
            clock.advance(0.1)
            receive(controller, rpm: 1000, busTenths: -125)
            XCTAssertEqual(service.currentRPM, 1000)
            XCTAssertEqual(try XCTUnwrap(service.currentSpeedKmh), 78.2, accuracy: 1e-9)
            let sample = try XCTUnwrap(service.record?.speedSamples.last)
            XCTAssertEqual(sample.speedKmh, 78.2, accuracy: 1e-9)
            XCTAssertEqual(sample.timestamp, clock.monotonic)
            XCTAssertEqual(service.record?.currentSamples.last?.busCurrentA, -12.5)
            XCTAssertEqual(service.record?.currentSamples.last?.rawRpm, 1000)
        }
    }

    @MainActor
    func testEditableCoefficientAndNegativeForwardSignAreFrozenInRecord() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start(targetSpeedKmh: 25, rpmKmhPerUnit: 0.1, rpmForwardSign: -1)
            clock.advance(0.1)
            receive(controller, rpm: -100)
            let record = try XCTUnwrap(service.record)
            XCTAssertEqual(record.config.rpmKmhPerUnit, 0.1)
            XCTAssertEqual(record.config.rpmForwardSign, -1)
            XCTAssertEqual(record.config.targetSpeedKmh, 25)
            XCTAssertEqual(record.speedSamples.last?.speedKmh, 10)
            XCTAssertThrowsError(try service.start())
            XCTAssertTrue(record.conditions["时间基准"]?.contains("不是控制器硬件测量时刻") == true)
            XCTAssertTrue(record.conditions["系数来源"]?.contains("不代表已实车校准") == true)
        }
    }

    @MainActor
    func testRejectsInvalidConfigBeforeStarting() throws {
        try withServices { controller, service, _, _ in
            ready(controller)
            receive(controller, rpm: 0)
            for target in [9.0, 201, .nan, .infinity] {
                XCTAssertThrowsError(try service.start(targetSpeedKmh: target))
            }
            for coefficient in [0.0, -1, .nan, .infinity] {
                XCTAssertThrowsError(try service.start(rpmKmhPerUnit: coefficient))
            }
            XCTAssertThrowsError(try service.start(rpmForwardSign: 0))
            XCTAssertThrowsError(try service.start(rpmForwardSign: 2))
            XCTAssertNil(service.record)
        }
    }

    @MainActor
    func testSilenceWatchdogAbortsWithoutAnotherNotification() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            let count = service.record?.speedSamples.count
            clock.advance(0.501)
            service.tick()
            XCTAssertFalse(service.isActive)
            XCTAssertFalse(service.hasFreshSnapshot)
            XCTAssertNil(service.currentRPM)
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertEqual(service.record?.speedSamples.count, count)
            XCTAssertEqual(service.records.count, 1)
            XCTAssertTrue(service.record?.endReason?.contains("500 ms") == true)
            XCTAssertThrowsError(try service.start())
        }
    }

    @MainActor
    func testStaleDataBeforeFirstRunSampleAndBeforeStartIsRejected() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            clock.advance(0.501)
            XCTAssertThrowsError(try service.start())
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.501)
            service.tick()
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertTrue(try XCTUnwrap(service.record).speedSamples.isEmpty)
        }
    }

    @MainActor
    func testLateReturningFrameCannotBridgeGapOrResumeRun() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            clock.advance(0.6)
            receive(controller, rpm: 1000)
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertEqual(service.record?.speedSamples.count, 1)
            XCTAssertEqual(service.currentRPM, 1000, "新帧可供下一次测试查看，不能补回旧会话")
        }
    }

    @MainActor
    func testPauseAndDisconnectInterruptAndSaveOnce() throws {
        try withServices { controller, service, _, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            controller.setPollingEnabled(false)
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertEqual(service.records.count, 1)
            controller.disconnect()
            XCTAssertEqual(service.records.count, 1)
            XCTAssertNil(service.currentSpeedKmh)
            XCTAssertFalse(service.canStart)
        }
    }

    @MainActor
    func testBackgroundNotificationWorksWithoutAccelerationPage() throws {
        try withServices { controller, service, _, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertFalse(service.hasFreshSnapshot)
            XCTAssertEqual(service.records.count, 1)
            service.applicationDidEnterBackground()
            XCTAssertEqual(service.records.count, 1)
        }
    }

    @MainActor
    func testRootStopReasonAPIIsAnInterruptionButUserStopIsPartial() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            service.stop(reason: "App 离开前台")
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertEqual(service.record?.endReason, "App 离开前台")
            XCTAssertFalse(service.canStart)
            clock.advance(0.1)
            receive(controller, rpm: 0)
            try service.start()
            service.stop()
            XCTAssertEqual(service.record?.phase, .partial)
            XCTAssertEqual(service.records.count, 2)
        }
    }

    @MainActor
    func testIdenticalReceiptClockAbortsRatherThanFabricateNextUpTimestamp() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            receive(controller, rpm: 1000) // Separate frames with exactly the same injected receipt clock.
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertEqual(service.record?.speedSamples.count, 1)
            XCTAssertEqual(service.record?.currentSamples.count, 1)
            XCTAssertTrue(service.record?.endReason?.contains("重复或倒退") == true)
            XCTAssertTrue(service.record?.result(for: .rpm)?.splits.isEmpty == true)
        }
    }

    @MainActor
    func testWallClockJumpDoesNotAffectMonotonicSamples() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            clock.date = Date(timeIntervalSince1970: 1)
            clock.monotonic += 0.1
            receive(controller, rpm: 0)
            XCTAssertTrue(service.isActive)
            XCTAssertEqual(service.record?.speedSamples.last?.timestamp, clock.monotonic)
            service.stop()
            XCTAssertTrue(try XCTUnwrap(service.record?.endedAt) >= service.record!.startedAt)
        }
    }

    @MainActor
    func testBackwardsMonotonicClockInterruptsWithoutAppendingSamples() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            clock.monotonic -= 1
            service.tick()
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertEqual(service.record?.speedSamples.count, 1)
            XCTAssertNil(service.pendingSaveRecord)
            XCTAssertTrue(try XCTUnwrap(service.record?.endedAt) >= service.record!.startedAt)
        }
    }

    @MainActor
    func testCompletedSplitsJSONReloadShareAndDelete() throws {
        try withServices { controller, service, clock, directory in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start(targetSpeedKmh: 25, rpmKmhPerUnit: 1)
            let base = clock.monotonic
            for index in 0...21 {
                clock.setUptime(base + Double(index) / 10)
                receive(controller, rpm: 0)
            }
            for (index, rpm) in [2, 5, 10, 15, 20, 25, 25].enumerated() {
                clock.setUptime(base + 2.2 + Double(index) / 10)
                receive(controller, rpm: rpm)
            }
            let record = try XCTUnwrap(service.record)
            let result = try XCTUnwrap(record.result(for: .rpm))
            XCTAssertEqual(record.phase, .completed)
            XCTAssertEqual(result.splits.map(\.targetSpeedKmh), [10, 20, 25])
            XCTAssertEqual(try XCTUnwrap(result.splits.last?.cumulativeSeconds),
                           result.splits.reduce(0) { $0 + $1.segmentSeconds }, accuracy: 1e-9)
            XCTAssertEqual(try service.historyStore.loadAll(), [record], "JSON 保留日期的小数秒和完整分段 / 样本")
            let exportDirectory = directory.appendingPathComponent("exports")
            let exported = try service.historyStore.exportJSON(record, to: exportDirectory)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any]
            XCTAssertEqual(json?["id"] as? String, record.id)
            XCTAssertEqual((json?["speedSamples"] as? [Any])?.count, record.speedSamples.count)
            XCTAssertEqual((json?["currentSamples"] as? [Any])?.count, record.currentSamples.count)
            XCTAssertNotNil(json?["conditions"])
            let shared = try service.exportJSON(record)
            defer { try? FileManager.default.removeItem(at: shared) }
            XCTAssertEqual(service.lastExportURL, shared)
            service.clearExportURL()
            XCTAssertNil(service.lastExportURL)
            service.delete(record)
            XCTAssertTrue(service.records.isEmpty)
            XCTAssertTrue(try service.historyStore.loadAll().isEmpty)
            XCTAssertNil(service.record)
        }
    }

    @MainActor
    func testSaveFailureRetainsRecordBlocksNewRunAndRetriesIdempotently() throws {
        try withServices(blockHistory: true) { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            service.stop()
            let pending = try XCTUnwrap(service.pendingSaveRecord)
            XCTAssertNotNil(service.historyError)
            XCTAssertThrowsError(try service.start())
            XCTAssertTrue(service.records.isEmpty)
            service.delete(pending)
            XCTAssertEqual(service.pendingSaveRecord?.id, pending.id)
            try FileManager.default.removeItem(at: service.historyStore.directory) // exact test-owned blocking file
            service.retryPendingSave()
            XCTAssertNil(service.pendingSaveRecord)
            XCTAssertNil(service.historyError)
            XCTAssertEqual(service.records.map(\.id), [pending.id])
            service.retryPendingSave()
            XCTAssertEqual(service.records.count, 1)
            XCTAssertEqual(try service.historyStore.loadAll().count, 1)
        }
    }

    @MainActor
    func testStoreRejectsPathTraversalAndReportsCorruptJSONWithoutDeletingIt() throws {
        try withServices { controller, service, _, directory in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            service.stop()
            let record = try XCTUnwrap(service.record)
            XCTAssertThrowsError(try service.historyStore.delete(id: "../outside"))
            XCTAssertThrowsError(try service.historyStore.delete(id: "a/b"))
            let corruptURL = service.historyStore.directory.appendingPathComponent("broken.json")
            try Data("not json".utf8).write(to: corruptURL)
            XCTAssertThrowsError(try service.historyStore.loadAll())
            service.reloadHistory()
            XCTAssertNotNil(service.historyError)
            XCTAssertEqual(service.records.map(\.id), [record.id], "读取失败不抹掉已经展示的历史")
            XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside.json").path))
        }
    }

    @MainActor
    func testReadsPreviousISO8601HistoryAndPreservesSignedCurrent() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0, busTenths: -125)
            service.stop()
            let record = try XCTUnwrap(service.record)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: service.historyStore.directory.appendingPathComponent("\(record.id).json"))
            let loaded = try XCTUnwrap(service.historyStore.loadAll().first)
            XCTAssertEqual(loaded.currentSamples.first?.busCurrentA, -12.5)
            XCTAssertEqual(loaded.config, record.config)
            XCTAssertEqual(loaded.speedSamples, record.speedSamples)
        }
    }

    @MainActor
    func testDeleteAndExportErrorsAreVisibleAndRetainHistory() throws {
        try withServices { controller, service, _, directory in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            service.stop()
            let record = try XCTUnwrap(service.record)
            let file = service.historyStore.directory.appendingPathComponent("\(record.id).json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file.appendingPathComponent("child"))
            // A nonempty directory occupying the record path must never be recursively deleted.
            service.delete(record)
            XCTAssertNotNil(service.historyError)
            XCTAssertEqual(service.records.count, 1)
            let blockedExport = directory.appendingPathComponent("blocked-export")
            try Data().write(to: blockedExport)
            XCTAssertThrowsError(try service.historyStore.exportJSON(record, to: blockedExport))
        }
    }

    @MainActor
    func testNonfiniteClockSafelyAbortsAndPersistsWithoutInventedSamples() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.monotonic = .nan
            service.tick()
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertTrue(try XCTUnwrap(service.record).speedSamples.isEmpty)
            XCTAssertNil(service.pendingSaveRecord)
            XCTAssertEqual(service.records.count, 1)
        }
    }

    @MainActor
    func testConfirmedPartialSplitsSurviveDisconnect() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start(targetSpeedKmh: 50, rpmKmhPerUnit: 1)
            let base = clock.monotonic
            for index in 0...21 {
                clock.setUptime(base + Double(index) / 10)
                receive(controller, rpm: 0)
            }
            for (index, rpm) in [2, 5, 10, 15].enumerated() {
                clock.setUptime(base + 2.2 + Double(index) / 10)
                receive(controller, rpm: rpm)
            }
            XCTAssertEqual(service.record?.result(for: .rpm)?.splits.map(\.targetSpeedKmh), [10])
            controller.disconnect()
            let record = try XCTUnwrap(service.record)
            XCTAssertEqual(record.phase, .interrupted)
            XCTAssertEqual(record.result(for: .rpm)?.splits.map(\.targetSpeedKmh), [10])
            XCTAssertEqual(try service.historyStore.loadAll(), [record])
        }
    }

    @MainActor
    func testStoreAndServiceExportRejectUnsafeRecordID() throws {
        try withServices { _, service, _, _ in
            let session = AccelerationTestSession()
            try session.start(at: 0, id: "../outside")
            let record = try XCTUnwrap(session.finish(at: 1))
            XCTAssertThrowsError(try service.historyStore.save(record))
            XCTAssertThrowsError(try service.exportJSON(record))
            XCTAssertNotNil(service.historyError)
            XCTAssertNil(service.lastExportURL)
        }
    }

    @MainActor
    func testBatchedNotificationAbortsEvenWhenReceiptClockAdvancesBetweenEvents() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            XCTAssertNotNil(controller.nextQuery())
            controller.queryWriteDidComplete()
            // Advance the injected clock between real parse events, reproducing
            // plausible but false microsecond timing from one BLE notification.
            let subscription = controller.$latestSnapshot.dropFirst().sink { _ in clock.advance(0.000_001) }
            defer { subscription.cancel() }
            controller.receiveNotification(frame(rpm: 0) + frame(rpm: 1000))
            XCTAssertEqual(service.record?.phase, .interrupted)
            XCTAssertTrue(service.record?.endReason?.contains("多帧合批无法确定帧间时序") == true)
            XCTAssertEqual(service.record?.speedSamples.count, 0)
            XCTAssertEqual(service.record?.currentSamples.count, 0)
            XCTAssertEqual(service.currentRPM, 1000, "保留真实快照展示，不将合批当成有效计时")
            XCTAssertNotNil(service.busCurrentA)
            XCTAssertFalse(service.hasFreshSnapshot)
            XCTAssertFalse(service.canStart)
            XCTAssertEqual(service.records.count, 1)
            XCTAssertThrowsError(try service.start())
            clock.advance(0.1)
            receive(controller, rpm: 0)
            XCTAssertTrue(service.canStart)
        }
    }

    @MainActor
    func testConditionsProviderSnapshotMergesIntoRecordAndDropsEmptyValues() throws {
        try withServices(conditionsProvider: { ["开始时 SOC": "87%", "开始时电池电压": "72.3 V", "开始时 BMS": ""] }) { controller, service, _, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            let conditions = try XCTUnwrap(service.record).conditions
            XCTAssertEqual(conditions["开始时 SOC"], "87%")
            XCTAssertEqual(conditions["开始时电池电压"], "72.3 V")
            XCTAssertNil(conditions["开始时 BMS"], "空值不写入，不造键")
            XCTAssertTrue(conditions["时间基准"]?.contains("不是控制器硬件测量时刻") == true)
        }
    }

    @MainActor
    func testElapsedOnlyAfterDepartureAndCurrentPeaksTrackMagnitude() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start(targetSpeedKmh: 50, rpmKmhPerUnit: 1)
            let base = clock.monotonic
            for index in 0...21 {
                clock.setUptime(base + Double(index) / 10)
                receive(controller, rpm: 0)
            }
            XCTAssertNil(service.elapsedSeconds, "静止等待阶段不显示伪零耗时")
            clock.advance(0.1)
            receive(controller, rpm: 2, busTenths: -100) // 首个 ≥1 km/h 运动候选
            clock.advance(0.1)
            receive(controller, rpm: 5, busTenths: -250) // 第二候选确认起步，进入 running
            service.tick()
            XCTAssertNotNil(service.elapsedSeconds)
            XCTAssertGreaterThan(try XCTUnwrap(service.elapsedSeconds), 0)
            // 峰值按幅值取最大且保留符号：-25 A 的幅值大于 -10 A。
            XCTAssertEqual(try XCTUnwrap(service.peakBusCurrentA), -25.0, accuracy: 0.05)
            XCTAssertEqual(try XCTUnwrap(service.peakPhasePeakCurrentA), 20.0, accuracy: 0.05)
            service.stop()
            service.tick()
            XCTAssertNil(service.elapsedSeconds, "结束后清空，避免把上次耗时当作新测试数据")
        }
    }

    @MainActor
    func testCheckpointRecoversActiveRunAsInterruptedRecord() throws {
        try withServices(checkpointInterval: 0) { controller, service, clock, root in
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            clock.advance(0.1)
            receive(controller, rpm: 0)
            let checkpoint = AccelerationCheckpointStore(directory: root.appendingPathComponent("checkpoint"))
            XCTAssertTrue(waitForFile(checkpoint.fileURL), "start 后应写入检查点")
            // 模拟进程被杀：旧会话不 finish，同一目录构造新服务启动恢复。
            let recovered = AccelerationService(controller: controller,
                historyStore: AccelerationHistoryStore(directory: root.appendingPathComponent("acceleration")),
                wallClock: { clock.date }, monotonicClock: { clock.monotonic + 1_000 },
                checkpointStore: AccelerationCheckpointStore(directory: root.appendingPathComponent("checkpoint")))
            XCTAssertEqual(recovered.records.count, 1)
            let record = try XCTUnwrap(recovered.records.first)
            XCTAssertEqual(record.phase, .interrupted)
            XCTAssertEqual(record.endReason, AccelerationCheckpointStore.recoveryEndReason)
            XCTAssertFalse(record.isActive)
            XCTAssertNil(recovered.pendingSaveRecord, "恢复记录直接落盘，不阻塞下一次测试")
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.fileURL.path), "恢复落盘后清除检查点")
        }
    }

    @MainActor
    func testCheckpointFileClearedAfterNormalFinish() throws {
        try withServices(checkpointInterval: 0) { controller, service, clock, root in
            let checkpoint = AccelerationCheckpointStore(directory: root.appendingPathComponent("checkpoint"))
            ready(controller)
            receive(controller, rpm: 0)
            try service.start()
            XCTAssertTrue(waitForFile(checkpoint.fileURL))
            clock.advance(0.1)
            receive(controller, rpm: 0)
            service.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.fileURL.path), "正常保存后删除检查点")
            XCTAssertEqual(service.records.count, 1)
        }
    }

    @MainActor
    func testCorruptCheckpointIsDiscardedAndReported() throws {
        try withServices { controller, service, _, root in
            let checkpoint = AccelerationCheckpointStore(directory: root.appendingPathComponent("checkpoint"))
            try FileManager.default.createDirectory(at: checkpoint.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: checkpoint.fileURL)
            let recovered = AccelerationService(controller: controller, historyStore: service.historyStore,
                wallClock: { Date() }, monotonicClock: { 100 }, checkpointStore: checkpoint)
            XCTAssertEqual(recovered.records.count, 0)
            XCTAssertTrue(recovered.historyError?.contains("损坏") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.fileURL.path))
        }
    }

    @MainActor
    func testBatchDeleteRemovesSavedRecordsAndSkipsActiveOnes() throws {
        try withServices { controller, service, clock, _ in
            ready(controller)
            receive(controller, rpm: 0)
            for index in 0..<2 {
                if index > 0 {
                    clock.advance(0.1)
                    receive(controller, rpm: 0)
                }
                try service.start()
                clock.advance(0.1)
                receive(controller, rpm: 0)
                service.stop()
            }
            XCTAssertEqual(service.records.count, 2)
            service.delete(service.records)
            XCTAssertEqual(service.records.count, 0)
            XCTAssertNil(service.historyError)

            clock.advance(0.1)
            receive(controller, rpm: 0)
            try service.start()
            service.delete([try XCTUnwrap(service.record)])
            XCTAssertTrue(service.isActive, "进行中的记录不能被批量删除")
            XCTAssertTrue(service.historyError?.contains("跳过 1 条") == true)
            service.stop()
        }
    }

    /// 检查点写入在后台串行队列执行；测试轮询文件出现，避免固定 sleep。
    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @MainActor private func ready(_ controller: ControllerBluetoothService) {
        controller.setPollingEnabled(true)
        controller.prepareSession(deviceID: UUID(), name: "APT test fixture")
        controller.notificationsDidBecomeReady()
    }

    @MainActor private func receive(_ controller: ControllerBluetoothService, rpm: Int, busTenths: Int = 0) {
        XCTAssertNotNil(controller.nextQuery())
        controller.queryWriteDidComplete()
        controller.receiveNotification(frame(rpm: rpm, busTenths: busTenths))
    }

    private func frame(rpm: Int, busTenths: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 39)
        bytes[0] = 0x0D; bytes[1] = 0x0D; bytes[2] = 0x0D
        bytes[3] = 0x24; bytes[4] = 0x01; bytes[5] = 0x1F
        func set(_ offset: Int, _ value: Int) {
            let bits = UInt16(truncatingIfNeeded: value)
            bytes[6 + offset] = UInt8(bits & 0xFF)
            bytes[7 + offset] = UInt8(bits >> 8)
        }
        set(0, 723); set(2, busTenths); set(4, rpm); set(8, 200)
        return Data(bytes)
    }

    @MainActor private final class Clock {
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        var monotonic: TimeInterval = 10
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds); monotonic += seconds }
        func setUptime(_ timestamp: TimeInterval) { advance(timestamp - monotonic) }
    }

    @MainActor private func withServices(blockHistory: Bool = false,
        conditionsProvider: (@MainActor () -> [String: String])? = nil,
        checkpointInterval: TimeInterval = 2,
        _ body: (ControllerBluetoothService, AccelerationService, Clock, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccelerationTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clock = Clock()
        let controller = ControllerBluetoothService(historyStore: ControllerHistoryStore(directory: root.appendingPathComponent("controller")),
            clock: { clock.date }, uptime: { clock.monotonic }, createsBluetoothManager: false)
        let history = root.appendingPathComponent("acceleration")
        if blockHistory { try Data("blocked".utf8).write(to: history) }
        let service = AccelerationService(controller: controller, historyStore: AccelerationHistoryStore(directory: history),
            wallClock: { clock.date }, monotonicClock: { clock.monotonic },
            conditionsProvider: conditionsProvider,
            checkpointStore: AccelerationCheckpointStore(directory: root.appendingPathComponent("checkpoint")),
            checkpointInterval: checkpointInterval)
        defer {
            controller.disconnect()
            try? FileManager.default.removeItem(at: root) // UUID-named test sandbox only
        }
        try body(controller, service, clock, root)
    }
}
