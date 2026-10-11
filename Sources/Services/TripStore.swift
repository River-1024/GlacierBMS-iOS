import ANTuRideDomain
import Foundation

/// 行程本地持久化：`Application Support/Trips/<uuid>.json`。
///
/// 不用 Documents（避免暴露给「文件」App 被误删），也不用 Caches
/// （可能被系统清理）；与日志存储目录策略一致。
///
/// - Note: 类型与 `init` 必须 public——`TripSessionService.init` 的
///   默认参数引用了本类型（Swift 可见性规则，CI 已踩过一次）。
public struct TripStore {
    public let directory: URL

    /// - Parameter directory: 注入自定义目录仅用于测试；默认 Application Support/Trips。
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Trips", isDirectory: true)
        }
    }

    func save(_ trip: Trip) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Self.fileURL(for: trip.id, in: directory)
        let data = try JSONEncoder().encode(trip)
        try data.write(to: url, options: .atomic)
        AppLog.location.info("行程已保存：\(trip.id.uuidString)（\(data.count) 字节，\(trip.segments.count) 段）")
    }

    func loadAll() throws -> [Trip] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "json" }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError { return [] }
            throw error
        }

        let trips = files.compactMap { url -> Trip? in
            do {
                return try JSONDecoder().decode(Trip.self, from: Data(contentsOf: url))
            } catch {
                // 单个文件损坏不拖垮列表：留证后跳过。
                AppLog.location.warning("行程文件损坏，已跳过：\(url.lastPathComponent)（\(error.localizedDescription)）")
                return nil
            }
        }
        return trips.sorted { $0.startedAt > $1.startedAt }
    }

    func delete(id: UUID) throws {
        let url = Self.fileURL(for: id, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        AppLog.location.info("行程已删除：\(id.uuidString)")
    }

    enum ExportFormat: String {
        case json, csv
    }

    /// 分享的是独立持久化快照，不依赖 save 成功，也不随 sheet 关闭或行程删除清理。
    /// 自定义导出目录用于测试；默认 Documents/Exports，与原始 Trips 目录分离。
    func export(_ trip: Trip, format: ExportFormat, to exportDirectory: URL? = nil) throws -> URL {
        let destination = exportDirectory ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Exports", isDirectory: true)
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // 保留原有 JSON 日期编码与 schema，可直接用原 JSONDecoder 往返。
            data = try encoder.encode(trip)
        case .csv:
            data = Self.sampleCSV(trip)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent(
            "trip-\(trip.id.uuidString)-\(UUID().uuidString).\(format.rawValue)"
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 只切当前页；不 flatten 整个行程，保留区间内原始样本顺序与索引。
    /// 页码从 0 开始；过界页夹到首/末页，空档案返回空范围。
    static func pageRange(count: Int, page: Int, pageSize: Int = 100) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let size = max(1, pageSize)
        let lastPage = (count - 1) / size
        let start = min(max(0, page), lastPage) * size
        return start..<(start + min(size, count - start))
    }

    /// RFC 4180：引号加倍，含逗号/引号/CR/LF 的单元格加引号，行以 CRLF 分隔。
    static func csvRow(_ fields: [String]) -> String {
        fields.map { value in
            guard value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") else {
                return value
            }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") + "\r\n"
    }

    private static func sampleCSV(_ trip: Trip) -> Data {
        let dates = ISO8601DateFormatter()
        dates.timeZone = TimeZone(secondsFromGMT: 0)
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Date?) -> String { value.map { dates.string(from: $0) } ?? "" }
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return String(value)
        }
        func validity(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "" }
        let headers = [
            "trip_id", "trip_started_at", "trip_ended_at", "segment_index", "segment_kind",
            "segment_started_at", "segment_ended_at", "sample_index", "timestamp",
            "gps_valid", "bms_valid", "latitude", "longitude", "speed_meters_per_second",
            "voltage_volts", "current_amps", "power_watts", "location_interval_seconds",
            "distance_meters", "energy_interval_seconds", "energy_wh"
        ]
        var data = Data(csvRow(headers).utf8)
        let tripFields = [trip.id.uuidString, date(trip.startedAt), date(trip.endedAt)]
        for (segmentIndex, segment) in trip.segments.enumerated() {
            let segmentFields = tripFields + [String(segmentIndex + 1), segment.kind.rawValue,
                                             date(segment.startedAt), date(segment.endedAt)]
            // nil/空 samples 都不补造行；暂停/缺口仍由 segment_index 的跳号保留边界。
            for (sampleIndex, sample) in (segment.samples ?? []).enumerated() {
                let fields = segmentFields + [
                    String(sampleIndex + 1), date(sample.timestamp),
                    validity(sample.gpsValid), validity(sample.bmsValid),
                    number(sample.latitude), number(sample.longitude), number(sample.speedMetersPerSecond),
                    number(sample.voltageVolts), number(sample.currentAmps), number(sample.powerWatts),
                    number(sample.locationIntervalSeconds), number(sample.distanceMeters),
                    number(sample.energyIntervalSeconds), number(sample.energyWh)
                ]
                data.append(contentsOf: csvRow(fields).utf8)
            }
        }
        return data
    }

    private static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
