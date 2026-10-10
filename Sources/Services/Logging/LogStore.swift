import Foundation

/// 日志的读取与管理服务，面向设置页 UI。
///
/// 职责边界：
/// - 只做「读 / 过滤 / 导出 / 清除」，不负责写入（写入由 `LogFileWriter` 承担）。
/// - 全部耗时操作在后台队列执行，结果回到主线程发布，避免阻塞 UI。
@MainActor
public final class LogStore: ObservableObject {
    /// 已加载的日志条目，按时间倒序（最新在前）。
    @Published public private(set) var entries: [LogEntry] = []
    /// 当前界面筛选的最低等级；`nil` 表示不按等级过滤。
    @Published public private(set) var filterLevel: LogLevel?
    /// 是否正在加载。
    @Published public private(set) var isLoading = false
    /// 全部日志文件的占用字节数。
    @Published public private(set) var totalBytes: Int = 0
    /// 最近一次操作的提示信息（用于 UI 反馈）。
    @Published public private(set) var lastActionMessage: String?

    /// 单次加载的最大条目数，防止超大日志拖垮界面。
    public let maximumLoadedEntries = 2000

    private let writer: LogFileWriter
    private let readQueue = DispatchQueue(label: "com.zjsf.anturide.logging.store", qos: .userInitiated)

    public init(writer: LogFileWriter = LogFileWriter()) {
        self.writer = writer
    }

    // MARK: - 读取

    /// 重新加载全部日志。按需应用等级过滤。
    public func reload() {
        isLoading = true
        let threshold = filterLevel
        readQueue.async { [weak self] in
            guard let self else { return }
            let text = self.writer.readAllText()
            var parsed: [LogEntry] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let entry = LogEntry.parse(line: String(line)) {
                    parsed.append(entry)
                }
            }
            // 最新在前。
            parsed.reverse()
            if let threshold {
                parsed = parsed.filter { $0.level >= threshold }
            }
            let limited = Array(parsed.prefix(self.maximumLoadedEntries))
            let bytes = self.writer.totalByteSize()
            Task { @MainActor in
                self.entries = limited
                self.totalBytes = bytes
                self.isLoading = false
            }
        }
    }

    /// 设置筛选等级并重新加载。
    public func setFilterLevel(_ level: LogLevel?) {
        filterLevel = level
        reload()
    }

    // MARK: - 导出与复制

    /// 导出为纯文本，可直接分享/保存。
    public func exportText() -> String {
        let header = exportHeader()
        let body = entries.reversed().map { $0.exportedText() }.joined(separator: "\n")
        return header + "\n" + body + "\n"
    }

    /// 生成一个可分享的临时文件 URL（.log），供系统分享面板（含「存储到文件」）使用。
    /// - Returns: 文件 URL；生成失败返回 `nil`。
    public func exportFileURL() -> URL? {
        let text = exportText()
        let stamp = LogStore.fileStampFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anturide-\(stamp).log")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            AppLog.ui.error("导出日志文件失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 供「复制」使用：返回当前（已过滤的）日志全文。
    public func copyText() -> String {
        exportText()
    }

    private func exportHeader() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let header = """
        # ANTuRide 日志导出
        # 导出时间: \(LogEntry.exportFormatter.string(from: Date()))
        # App 版本: \(version) (\(build))
        # 系统: \(ProcessInfo.processInfo.operatingSystemVersionString)
        # 条目数: \(entries.count)
        # 等级过滤: \(filterLevel?.tag ?? "全部")
        """
        return header
    }

    // MARK: - 清除

    /// 清空全部日志文件并刷新列表。
    public func clearAll() {
        let success = writer.clearAll()
        entries = []
        totalBytes = 0
        lastActionMessage = success ? "日志已清空" : "部分日志文件删除失败"
        AppLog.ui.notice("用户清空日志: \(success ? "成功" : "部分失败")")
        reload()
    }

    /// 清除 UI 上的瞬时提示。
    public func clearActionMessage() {
        lastActionMessage = nil
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f
    }()
}

// MARK: - 展示辅助

extension LogStore {
    /// 人类可读的体积文本。
    public var totalSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(totalBytes))
    }
}
