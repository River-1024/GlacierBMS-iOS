import Foundation

/// 日志文件的滚动写入器。
///
/// 设计约束（对应「先取证后动刀」要求）：
/// - **崩溃安全**：每条日志写入后立即 `synchronize`，确保 `fatalError` 之前落盘。
/// - **滚动上限**：单文件达到上限即滚动，最多保留 N 个历史文件，总占用有界。
/// - **线程安全**：通过内部串行队列串行化写入，避免多线程交错损坏行。
/// - **不抛出**：写入失败静默降级（日志系统自身故障不得拖垮 App）。
final class LogFileWriter {
    struct Configuration {
        var directoryName = "Logs"
        var fileNamePrefix = "anturide"
        var fileExtension = "log"
        /// 单文件字节上限，默认 2 MB。
        var maximumFileSize: Int = 2 * 1024 * 1024
        /// 保留的文件总数（含当前写入文件），默认 5 个 → 磁盘上限约 10 MB。
        var maximumFileCount = 5
    }

    private let config: Configuration
    private let queue = DispatchQueue(label: "com.zjsf.anturide.logging.writer", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentFileSize: Int = 0
    private var currentFileURL: URL?

    init(config: Configuration = Configuration()) {
        self.config = config
    }

    // MARK: - 目录

    /// 日志目录：`Application Support/Logs`。首次调用时创建。
    /// 选择 Application Support 而非 Documents/Caches：
    /// 前者不会被系统在存储紧张时清理，也不会暴露给「文件」App 被用户误删。
    func logDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(config.directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 按时间倒序列出全部日志文件（最新在前）。
    func logFiles() -> [URL] {
        guard let dir = try? logDirectory() else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == config.fileExtension }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    /// 全部日志文件占用的总字节数。
    func totalByteSize() -> Int {
        logFiles().reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + size
        }
    }

    // MARK: - 写入

    /// 追加一行。所有失败均被吞掉：日志系统不得成为新的崩溃源。
    func append(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            do {
                try self.prepareIfNeeded(nextWriteSize: data.count)
                guard let handle = self.fileHandle else { return }
                try handle.write(contentsOf: data)
                // 崩溃安全的关键：立即落盘，而非等待系统缓冲刷写。
                try handle.synchronize()
                self.currentFileSize += data.count
            } catch {
                // 静默降级：关闭句柄，下一行会尝试重新打开。
                self.closeHandle()
            }
        }
    }

    /// 确保有可写句柄；必要时滚动。
    private func prepareIfNeeded(nextWriteSize: Int) throws {
        if fileHandle == nil {
            try openNewestOrCreate()
        }
        // 若追加后会超过上限，则滚动到新文件。
        if currentFileSize > 0, currentFileSize + nextWriteSize > config.maximumFileSize {
            try roll()
        }
    }

    /// 打开当前最新文件续写；若不存在则创建。
    private func openNewestOrCreate() throws {
        if let newest = logFiles().first {
            let handle = try FileHandle(forWritingTo: newest)
            try handle.seekToEnd()
            fileHandle = handle
            currentFileURL = newest
            currentFileSize = (try? newest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return
        }
        try createNewFile()
    }

    /// 滚动：关闭当前句柄，创建新文件，并清理超出保留数的旧文件。
    private func roll() throws {
        closeHandle()
        try createNewFile()
        pruneOldFiles()
    }

    private func createNewFile() throws {
        let dir = try logDirectory()
        let stamp = LogFileWriter.fileStampFormatter.string(from: Date())
        let name = "\(config.fileNamePrefix)-\(stamp).\(config.fileExtension)"
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        fileHandle = handle
        currentFileURL = url
        currentFileSize = 0
    }

    /// 只保留最新的 `maximumFileCount` 个文件，其余删除。
    private func pruneOldFiles() {
        let files = logFiles()
        guard files.count > config.maximumFileCount else { return }
        for url in files.dropFirst(config.maximumFileCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFileURL = nil
        currentFileSize = 0
    }

    // MARK: - 清除

    /// 删除全部日志文件并释放句柄。返回是否全部删除成功。
    @discardableResult
    func clearAll() -> Bool {
        queue.sync {
            closeHandle()
            var allRemoved = true
            for url in logFiles() {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    allRemoved = false
                }
            }
            return allRemoved
        }
    }

    /// 读取全部日志文件的原始内容（按文件从旧到新拼接）。
    func readAllText() -> String {
        queue.sync {
            let files = logFiles().reversed()
            var combined = ""
            for url in files {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    combined += text
                }
            }
            return combined
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f
    }()
}
