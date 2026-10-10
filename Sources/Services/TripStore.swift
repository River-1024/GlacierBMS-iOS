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

    private static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
