import ANTuRideDomain
import Combine
import Foundation
import UIKit

/// RPM-only, read-only controller subscription. Timing is the phone's monotonic
/// snapshot-receipt clock, NOT a controller hardware measurement timestamp.
@MainActor
public final class AccelerationService: ObservableObject {
    public enum ServiceError: LocalizedError, Equatable {
        case controllerUnavailable
        case invalidNumber(String)
        case pendingSave

        public var errorDescription: String? {
            switch self {
            case .controllerUnavailable: return "需要控制器实时查询状态及 500 ms 内新收到的完整帧。"
            case let .invalidNumber(name): return "\(name)无效，请检查输入范围。"
            case .pendingSave: return "上一条记录尚未保存，请先重试保存，不能覆盖记录。"
            }
        }
    }

    public static let defaultRPMKmhPerUnit = AccelerationConfig.defaultRPMCoefficient
    public static let snapshotTimeout: TimeInterval = 0.5

    @Published public private(set) var record: AccelerationRecord?
    @Published public private(set) var records: [AccelerationRecord] = []
    @Published public private(set) var controllerState: ControllerBluetoothService.State
    @Published public private(set) var currentRPM: Int?
    @Published public private(set) var currentSpeedKmh: Double?
    @Published public private(set) var busCurrentA: Double?
    @Published public private(set) var phasePeakCurrentA: Double?
    @Published public private(set) var hasFreshSnapshot = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var historyError: String?
    @Published public private(set) var pendingSaveRecord: AccelerationRecord?
    @Published public private(set) var lastExportURL: URL?
    /// 运行读数：耗时仅 running 阶段有值（相对渠道起步时刻）；电流峰值为本次运行累计。
    @Published public private(set) var elapsedSeconds: Double?
    @Published public private(set) var peakBusCurrentA: Double?
    @Published public private(set) var peakPhasePeakCurrentA: Double?

    public let historyStore: AccelerationHistoryStore
    private let controller: ControllerBluetoothService
    private let wallClock: () -> Date
    private let monotonicClock: () -> TimeInterval
    private let conditionsProvider: (@MainActor () -> [String: String])?
    private let checkpointStore: AccelerationCheckpointStore
    private let checkpointInterval: TimeInterval
    private var lastCheckpointWrite: Date?
    private var subscriptions = Set<AnyCancellable>()
    private var activeSession: AccelerationTestSession?
    private var lastReceiptTimestamp: TimeInterval?
    private var lastSampleTimestamp: TimeInterval?
    private var sequence: Int64 = 0
    private var displayConfig = AccelerationConfig(rpmKmhPerUnit: AccelerationService.defaultRPMKmhPerUnit)

    public init(
        controller: ControllerBluetoothService,
        historyStore: AccelerationHistoryStore = AccelerationHistoryStore(),
        wallClock: @escaping () -> Date = Date.init,
        monotonicClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        conditionsProvider: (@MainActor () -> [String: String])? = nil,
        checkpointStore: AccelerationCheckpointStore = AccelerationCheckpointStore(),
        checkpointInterval: TimeInterval = 2
    ) {
        self.controller = controller
        self.historyStore = historyStore
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
        self.conditionsProvider = conditionsProvider
        self.checkpointStore = checkpointStore
        self.checkpointInterval = checkpointInterval
        self.controllerState = controller.state
        recoverFromCheckpoint()
        subscribeToController()
        Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &subscriptions)
        // Service-owned: navigating away from the page must not disable background cancellation.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.applicationDidEnterBackground() }
            .store(in: &subscriptions)
    }

    public var isActive: Bool { record?.isActive == true }
    public var canStart: Bool {
        !isActive && pendingSaveRecord == nil && controllerState == .ready && hasFreshSnapshot
    }

    public func start(targetSpeedKmh: Double = 50,
                      rpmKmhPerUnit: Double = AccelerationService.defaultRPMKmhPerUnit,
                      rpmForwardSign: Int = 1) throws {
        guard !isActive else { throw AccelerationError.sessionAlreadyActive }
        guard pendingSaveRecord == nil else { throw ServiceError.pendingSave }
        tick()
        guard controllerState == .ready, hasFreshSnapshot else {
            throw ServiceError.controllerUnavailable
        }
        guard targetSpeedKmh.isFinite, (10...200).contains(targetSpeedKmh) else {
            throw ServiceError.invalidNumber("目标速度（10–200 km/h）")
        }
        guard rpmKmhPerUnit.isFinite, rpmKmhPerUnit > 0 else {
            throw ServiceError.invalidNumber("RPM 系数（正有限数）")
        }
        guard rpmForwardSign == 1 || rpmForwardSign == -1 else {
            throw ServiceError.invalidNumber("正向符号（+1 或 -1）")
        }
        let config = AccelerationConfig(targetSpeedKmh: targetSpeedKmh,
            rpmKmhPerUnit: rpmKmhPerUnit, rpmForwardSign: rpmForwardSign,
            algorithmVersion: "rpm-receipt-acceleration-v1")
        var conditions = [
            "测速渠道": "控制器原始 RPM 单渠道",
            "换算公式": "速度(km/h) = rawRPM × 系数 × forwardSign",
            "系数来源": "用户设定；默认 0.0782，不代表已实车校准",
            "时间基准": "手机接收完整快照事件时的单调时钟；不是控制器硬件测量时刻",
            "计时限制": "含蓝牙传输及手机调度延迟；分段为接收时序插值估计，不是硬件精度",
            "控制器": controller.connectedDeviceName ?? "未命名控制器",
            "传感器边界": "未接入 GPS/IMU；不生成模拟结果"
        ]
        // 开始时刻的环境快照（SOC/电压/温度等）来自组合根注入；无连接的键不出现，不造值。
        for (key, value) in conditionsProvider?() ?? [:] where !value.isEmpty {
            conditions[key] = value
        }
        let session = AccelerationTestSession(config: config)
        let started = try session.start(at: monotonicClock(), date: wallClock(),
                                       id: UUID().uuidString, conditions: conditions)
        activeSession = session
        lastSampleTimestamp = nil
        sequence = 0
        elapsedSeconds = nil
        peakBusCurrentA = nil
        peakPhasePeakCurrentA = nil
        lastCheckpointWrite = nil
        displayConfig = config
        currentSpeedKmh = currentRPM.flatMap { config.rpmSpeedMps(rawRpm: Double($0)) }.map { $0 * 3.6 }
        record = started
        lastError = nil
        writeCheckpointIfDue(started)
        // Do not replay the cached pre-start snapshot as a new sample.
    }

    public func stop() { finishActive(reason: "用户结束", interrupted: false) }

    /// Composition-root lifecycle API: leaving the foreground is an interruption,
    /// not a successful/manual completion. Invalidate readiness until another receipt.
    public func stop(reason: String) {
        finishActive(reason: reason, interrupted: true)
        clearLiveValues()
    }

    public func applicationDidEnterBackground() {
        finishActive(reason: "应用进入后台，实时采样已中止", interrupted: true)
        clearLiveValues()
    }

    public func delete(_ record: AccelerationRecord) {
        guard pendingSaveRecord?.id != record.id, !record.isActive else {
            historyError = "未保存或进行中的记录不能删除，请先结束并保存。"
            return
        }
        do {
            try historyStore.delete(id: record.id)
            records.removeAll { $0.id == record.id }
            if self.record?.id == record.id { self.record = nil }
            historyError = nil
        } catch { historyError = "删除失败：\(error.localizedDescription)" }
    }

    /// 批量删除历史记录；进行中或未保存的记录跳过，结果汇总进 historyError。
    public func delete(_ records: [AccelerationRecord]) {
        var deletedCount = 0
        var skippedCount = 0
        var failedCount = 0
        var lastFailure: String?
        for record in records {
            guard pendingSaveRecord?.id != record.id, !record.isActive else {
                skippedCount += 1
                continue
            }
            do {
                try historyStore.delete(id: record.id)
                self.records.removeAll { $0.id == record.id }
                if self.record?.id == record.id { self.record = nil }
                deletedCount += 1
            } catch {
                failedCount += 1
                lastFailure = error.localizedDescription
            }
        }
        if skippedCount == 0, failedCount == 0 {
            historyError = nil
        } else {
            var summary = ["已删除 \(deletedCount) 条"]
            if skippedCount > 0 { summary.append("跳过 \(skippedCount) 条进行中/未保存记录") }
            if failedCount > 0 { summary.append("\(failedCount) 条删除失败\(lastFailure.map { "：\($0)" } ?? "")") }
            historyError = summary.joined(separator: "；")
        }
    }

    @discardableResult
    public func exportJSON(_ record: AccelerationRecord) throws -> URL {
        do {
            let url = try historyStore.exportJSON(record)
            lastExportURL = url
            return url
        } catch {
            historyError = "导出失败：\(error.localizedDescription)"
            throw error
        }
    }

    public func retryPendingSave() {
        guard let pendingSaveRecord else { return }
        persist(pendingSaveRecord)
    }

    public func clearExportURL() { lastExportURL = nil }

    public func reloadHistory() {
        do {
            records = try historyStore.loadAll()
            if pendingSaveRecord == nil { historyError = nil }
        } catch { historyError = "读取历史记录失败：\(error.localizedDescription)" }
    }

    private func subscribeToController() {
        controller.$latestSnapshot
            // @Published initial replay is not a new receipt. Wait for the next real event.
            .dropFirst()
            .sink { [weak self] snapshot in self?.receive(snapshot) }
            .store(in: &subscriptions)
        controller.$state
            .sink { [weak self] state in
                guard let self else { return }
                self.controllerState = state
                if state != .ready {
                    self.finishActive(reason: "控制器实时链路不可用：\(state.text)", interrupted: true)
                    self.clearLiveValues()
                }
            }
            .store(in: &subscriptions)
    }

    private func receive(_ snapshot: ControllerTelemetrySnapshot?) {
        guard let snapshot, controllerState == .ready else {
            finishActive(reason: "控制器数据已断开或暂停，未补造速度样本", interrupted: true)
            clearLiveValues()
            return
        }
        // Read the event argument, never controller.latestSnapshot during @Published willSet.
        let timestamp = monotonicClock()
        guard timestamp.isFinite, timestamp >= 0 else {
            finishActive(reason: "手机单调接收时钟无效", interrupted: true)
            clearLiveValues()
            return
        }
        tick(at: timestamp) // Missing data cannot be bridged by the returning frame.
        let telemetry = snapshot.telemetry
        lastReceiptTimestamp = timestamp
        hasFreshSnapshot = !snapshot.timingAmbiguous
        currentRPM = telemetry.rpm
        busCurrentA = finite(telemetry.busCurrentA)
        phasePeakCurrentA = finite(telemetry.phasePeakCurrentA)
        if activeSession?.isActive == true {
            // 峰值按幅值比较、保留原符号：加速放电时母线电流为负，直接 max 会丢掉大幅值。
            if let bus = finite(telemetry.busCurrentA), abs(bus) >= abs(peakBusCurrentA ?? 0) {
                peakBusCurrentA = bus
            }
            if let phase = finite(telemetry.phasePeakCurrentA), abs(phase) >= abs(peakPhasePeakCurrentA ?? 0) {
                peakPhaseCurrentA = phase
            }
        }
        currentSpeedKmh = displayConfig.rpmSpeedMps(rawRpm: Double(telemetry.rpm)).map { $0 * 3.6 }
        if snapshot.timingAmbiguous {
            let reason = "多帧合批无法确定帧间时序，不能用于加速计时"
            lastError = reason
            finishActive(reason: reason, interrupted: true)
            // Keep genuine latest RPM/current for display, but not acceleration readiness or samples.
            return
        }
        guard let session = activeSession, session.isActive, let activeRecord = session.record else { return }
        guard lastSampleTimestamp.map({ timestamp > $0 }) ?? (timestamp >= activeRecord.referenceTimestamp) else {
            // No nextUp/fabricated timestamps for a batch or a backwards receive clock.
            finishActive(reason: "快照接收时钟重复或倒退，不能确定帧间时间", interrupted: true)
            return
        }
        lastSampleTimestamp = timestamp
        sequence += 1
        session.ingest(AccelerationCurrentSample(timestamp: timestamp,
            busCurrentA: telemetry.busCurrentA, phasePeakCurrentA: telemetry.phasePeakCurrentA,
            rawRpm: telemetry.rpm, sequence: sequence))
        if let speedMps = session.config.rpmSpeedMps(rawRpm: Double(telemetry.rpm)) {
            session.ingest(AccelerationSpeedSample(source: .rpm, timestamp: timestamp, speedMps: speedMps))
        } else {
            session.invalidate(.rpm, reason: "RPM × 系数 × 方向无法换算为有限速度", at: timestamp)
        }
        publishAndPersistIfFinished(session)
    }

    /// Independent silence watchdog. Also callable by AppTests with injected clocks.
    func tick() { tick(at: monotonicClock()) }

    private func tick(at timestamp: TimeInterval) {
        if let receipt = lastReceiptTimestamp,
           !timestamp.isFinite || timestamp < receipt || timestamp - receipt > Self.snapshotTimeout {
            finishActive(reason: "RPM 数据超时或接收时钟倒退（上限 500 ms），禁止跨缺样计时", interrupted: true)
            clearLiveValues()
        }
        if let session = activeSession {
            session.tick(at: timestamp)
            publishAndPersistIfFinished(session)
        }
        updateElapsed(at: timestamp)
    }

    private func clearLiveValues() {
        lastReceiptTimestamp = nil
        hasFreshSnapshot = false
        currentRPM = nil
        currentSpeedKmh = nil
        busCurrentA = nil
        phasePeakCurrentA = nil
        if elapsedSeconds != nil { elapsedSeconds = nil }
    }

    private func finishActive(reason: String, interrupted: Bool) {
        guard let session = activeSession, session.isActive, let previous = session.record else { return }
        let now = monotonicClock()
        let fallback = max(previous.referenceTimestamp, lastSampleTimestamp ?? previous.referenceTimestamp)
        _ = session.finish(at: now.isFinite ? max(now, fallback) : fallback,
                           reason: reason, interrupted: interrupted)
        if interrupted { lastError = reason }
        publishAndPersistIfFinished(session)
    }

    private func publishAndPersistIfFinished(_ session: AccelerationTestSession) {
        guard let updated = session.record else { return }
        record = updated
        guard !updated.isActive else {
            writeCheckpointIfDue(updated)
            return
        }
        activeSession = nil
        persist(updated)
    }

    private func persist(_ record: AccelerationRecord) {
        do {
            try historyStore.save(record)
            pendingSaveRecord = nil
            historyError = nil
            checkpointStore.clear()
            records.removeAll { $0.id == record.id }
            records.insert(record, at: 0)
            records.sort { $0.startedAt > $1.startedAt }
        } catch {
            pendingSaveRecord = record
            historyError = "记录保存失败，可重试：\(error.localizedDescription)"
        }
    }

    /// 崩溃兜底：start 立即写一次，之后按 checkpointInterval 节流写最新快照。
    private func writeCheckpointIfDue(_ record: AccelerationRecord) {
        guard record.isActive else { return }
        let now = wallClock()
        if let last = lastCheckpointWrite, now.timeIntervalSince(last) < checkpointInterval { return }
        lastCheckpointWrite = now
        checkpointStore.write(record)
    }

    /// 耗时只在 running 阶段有意义：armed 等待起步时显示伪零会误导计时。
    /// 相同值不重发，避免 10Hz tick 触发无意义的界面刷新。
    private func updateElapsed(at timestamp: TimeInterval) {
        let value: Double?
        if let record, record.isActive,
           let start = record.result(for: .rpm)?.startTimestamp {
            let elapsed = timestamp - start
            value = elapsed.isFinite && elapsed >= 0 ? elapsed : nil
        } else {
            value = nil
        }
        if value != elapsedSeconds { elapsedSeconds = value }
    }

    /// 启动时把崩溃残留的进行中检查点转成"已中断"记录；转换结果仍走历史校验落盘。
    private func recoverFromCheckpoint() {
        var corrupt = false
        switch checkpointStore.recover() {
        case .none:
            break
        case .record(let recovered):
            do {
                try historyStore.save(recovered)
                checkpointStore.clear()
            } catch {
                historyError = "检查点恢复失败：\(error.localizedDescription)"
            }
        case .corrupt:
            corrupt = true
        }
        reloadHistory()
        if corrupt { historyError = "发现损坏的进行中检查点，已丢弃；已保存历史不受影响。" }
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
}

/// JSON is the persistence source for acceleration records. Failed writes are retained by
/// AccelerationService so the UI can offer an explicit retry instead of dropping evidence.
public struct AccelerationHistoryStore {
    public enum StoreError: LocalizedError {
        case invalidRecord
        public var errorDescription: String? { "加速记录无效或时间顺序错误" }
    }

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("AccelerationHistory", isDirectory: true)
    }

    public func save(_ record: AccelerationRecord) throws {
        try validate(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder().encode(record).write(to: fileURL(record.id), options: .atomic)
    }

    public func loadAll() throws -> [AccelerationRecord] {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            return try files.filter { $0.pathExtension == "json" }.map { url in
                let record = try decoder().decode(AccelerationRecord.self, from: Data(contentsOf: url))
                try validate(record)
                guard url.lastPathComponent == "\(record.id).json" else { throw StoreError.invalidRecord }
                return record
            }.sorted {
                if $0.startedAt == $1.startedAt { return $0.id < $1.id }
                return $0.startedAt > $1.startedAt
            }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
    }

    public func delete(id: String) throws {
        guard isSafeID(id) else { throw StoreError.invalidRecord }
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.invalidRecord }
        // removeItem is recursive for directories: never let an ID delete a directory.
        try FileManager.default.removeItem(at: url)
    }

    public func exportJSON(_ record: AccelerationRecord,
                           to exportDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try validate(record)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent("acceleration-\(record.id).json")
        try encoder().encode(record).write(to: url, options: .atomic)
        return url
    }

    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Preserve subsecond wall-clock dates; elapsed timing remains monotonic.
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite {
                return Date(timeIntervalSince1970: seconds)
            }
            // Read the previous partial service's ISO-8601 records without rewriting them.
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效加速记录日期")
            }
            return date
        }
        return decoder
    }

    private func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private func validate(_ record: AccelerationRecord) throws {
        guard isSafeID(record.id), !record.isActive, record.endedAt != nil,
              record.referenceTimestamp.isFinite, record.referenceTimestamp >= 0,
              record.startedAt.timeIntervalSince1970.isFinite,
              record.endedAt?.timeIntervalSince1970.isFinite ?? true,
              record.endedAt.map { $0 >= record.startedAt } ?? true,
              (try? record.config.validate()) != nil else {
            throw StoreError.invalidRecord
        }
        guard record.speedSamples.count + record.currentSamples.count <= AccelerationTestSession.maximumSamples,
              record.results.count == 1, record.results.first?.source == .rpm,
              let coefficient = record.config.rpmKmhPerUnit, coefficient.isFinite, coefficient > 0 else {
            throw StoreError.invalidRecord
        }
        var lastTimestamp: TimeInterval?
        for sample in record.speedSamples {
            guard sample.timestamp.isFinite, sample.timestamp >= record.referenceTimestamp,
                  sample.speedMps.isFinite,
                  lastTimestamp.map({ sample.timestamp > $0 }) ?? true else {
                throw StoreError.invalidRecord
            }
            lastTimestamp = sample.timestamp
        }
        lastTimestamp = nil
        for sample in record.currentSamples {
            guard sample.timestamp.isFinite, sample.timestamp >= record.referenceTimestamp,
                  sample.busCurrentA.isFinite, sample.phasePeakCurrentA.isFinite,
                  lastTimestamp.map({ sample.timestamp >= $0 }) ?? true else { throw StoreError.invalidRecord }
            lastTimestamp = sample.timestamp
        }
    }
}
