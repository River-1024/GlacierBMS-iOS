import ANTuRideDomain
import Foundation

/// 保留旧七字段 JSON，并可选保存完整 telemetry；speed 没有已确认的协议来源。
/// 非有限数在 JSON 中编码为 NaN/Infinity/-Infinity 字符串，18 列导出使用 -- 占位。
public struct ControllerHistoryRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let deviceID: UUID
    public let deviceName: String
    public let startedAt: Date
    public let endedAt: Date
    public let samples: [ControllerSample]
    /// Optional for old JSON. Reports rejected duplicate/backward receive timestamps, not hardware time.
    public let timingWarning: String?

    public init(id: UUID = UUID(), deviceID: UUID, deviceName: String,
                startedAt: Date, endedAt: Date, samples: [ControllerSample], timingWarning: String? = nil) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
        self.timingWarning = timingWarning
    }
}

/// 独立于 BMS/行程的控制器历史。JSON 是持久化源；CSV/XLSX 对齐 Android 18 列。
/// 分享使用独立临时快照，不实现 Android 历史导入。
public struct ControllerHistoryStore {
    public enum ExportFormat: String, CaseIterable { case json, csv, xlsx }
    public enum StoreError: LocalizedError {
        case invalidRecord
        public var errorDescription: String? { "控制器记录时间或样本顺序无效" }
    }

    /// 加法 API：旧 loadAll() 仍只返回有效记录；页面可同时提示无法读取的文件。
    public struct LoadReport {
        public let records: [ControllerHistoryRecord]
        public let unreadableRecordIDs: [UUID]
    }

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ControllerHistory", isDirectory: true)
    }

    public func save(_ record: ControllerHistoryRecord) throws {
        try validate(record)
        let data = try encoder().encode(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(record.id), options: .atomic)
    }

    public func load(id: UUID) throws -> ControllerHistoryRecord {
        let record = try decoder().decode(ControllerHistoryRecord.self, from: Data(contentsOf: fileURL(id)))
        guard record.id == id else { throw StoreError.invalidRecord }
        try validate(record)
        return record
    }

    public func loadAll() throws -> [ControllerHistoryRecord] {
        try loadAllReportingFailures().records
    }

    public func loadAllReportingFailures() throws -> LoadReport {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return LoadReport(records: [], unreadableRecordIDs: [])
            }
            throw error
        }
        // 损坏文件保留供取证，单个损坏文件不影响其它记录。
        var records: [ControllerHistoryRecord] = []
        var unreadableRecordIDs: [UUID] = []
        for url in files {
            guard url.pathExtension == "json",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do { records.append(try load(id: id)) }
            catch { unreadableRecordIDs.append(id) }
        }
        records.sort {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.startedAt > $1.startedAt
        }
        return LoadReport(records: records, unreadableRecordIDs: unreadableRecordIDs.sorted {
            $0.uuidString < $1.uuidString
        })
    }

    public func delete(id: UUID) throws {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func export(_ record: ControllerHistoryRecord, format: ExportFormat,
                       to exportDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try validate(record)
        let data: Data
        switch format {
        case .json: data = try encoder().encode(record)
        case .csv, .xlsx:
            let session = ControllerRecordSession()
            for sample in record.samples { session.append(sample) }
            if format == .csv {
                data = Data(session.exportControllerCSV().utf8)
            } else {
                data = try session.exportControllerXLSX()
            }
        }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent("controller-\(record.id.uuidString).\(format.rawValue)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 每次分享持有独立快照，不会被同一记录的后续导出覆盖或清理。
    /// 调用方在分享结束后清理返回文件所在的独立目录。
    public func exportForSharing(_ record: ControllerHistoryRecord, format: ExportFormat,
                                 to exportDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let snapshotDirectory = exportDirectory.appendingPathComponent(
            "controller-export-\(UUID().uuidString)", isDirectory: true
        )
        do { return try export(record, format: format, to: snapshotDirectory) }
        catch {
            // 只清理本次拥有的快照目录，保留原记录及之前的导出。
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return decoder
    }

    private func validate(_ record: ControllerHistoryRecord) throws {
        func validDate(_ date: Date) -> Bool {
            let seconds = date.timeIntervalSince1970
            return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800
        }
        guard validDate(record.startedAt), validDate(record.endedAt), record.endedAt >= record.startedAt else {
            throw StoreError.invalidRecord
        }
        let session = ControllerRecordSession()
        for sample in record.samples {
            guard sample.timestamp >= record.startedAt, sample.timestamp <= record.endedAt,
                  session.append(sample) else { throw StoreError.invalidRecord }
        }
    }
}
