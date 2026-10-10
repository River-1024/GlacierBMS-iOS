import ANTuRideDomain
import Foundation

/// 本地记录格式 v1：复用 Domain 的七列采样；speed 没有已确认的协议来源。
/// 非有限数在 JSON 中编码为 NaN/Infinity/-Infinity 字符串，在 CSV 中为空单元格。
public struct ControllerHistoryRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let deviceID: UUID
    public let deviceName: String
    public let startedAt: Date
    public let endedAt: Date
    public let samples: [ControllerSample]

    public init(id: UUID = UUID(), deviceID: UUID, deviceName: String,
                startedAt: Date, endedAt: Date, samples: [ControllerSample]) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
    }
}

/// 独立于 BMS/行程的控制器历史。JSON 是持久化源，CSV/JSON 导出为独立临时文件。
/// 不提供 XLSX，也不声明与 Android 的十八列 XLSX/导入格式兼容。
public struct ControllerHistoryStore {
    public enum ExportFormat: String, CaseIterable { case json, csv }
    public enum StoreError: LocalizedError {
        case invalidRecord
        public var errorDescription: String? { "控制器记录时间或样本顺序无效" }
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
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError { return [] }
            throw error
        }
        // 损坏文件保留供取证，单个损坏文件不影响其它记录。
        return files.compactMap { url -> ControllerHistoryRecord? in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return try? load(id: id)
        }.sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.startedAt > $1.startedAt
        }
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
        case .csv:
            let session = ControllerRecordSession()
            for sample in record.samples { session.append(sample) }
            data = Data(session.exportCSV().utf8)
        }
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent("controller-\(record.id.uuidString).\(format.rawValue)")
        try data.write(to: url, options: .atomic)
        return url
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
