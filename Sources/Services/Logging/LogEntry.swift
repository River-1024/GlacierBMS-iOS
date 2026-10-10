import Foundation

/// 一条已落盘或已生成的日志记录。不可变值类型，便于跨线程传递与测试。
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    /// 产生日志的源文件（不含路径），用于定位。
    public let file: String
    /// 产生日志的函数名。
    public let function: String
    /// 产生日志的行号。
    public let line: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        level: LogLevel,
        category: String,
        message: String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.file = file
        self.function = function
        self.line = line
    }

    /// 落盘单行的分隔符。使用 `|` 分隔前四个固定字段，
    /// 后续字段可能含 `|`（如消息内的十六进制转储），因此解析时限制分割次数。
    static let fieldSeparator = " | "

    /// 序列化为单行文本。消息中的换行会被转义，保证「一行一记录」。
    public func serialized() -> String {
        let time = LogEntry.timestampFormatter.string(from: timestamp)
        let safeMessage = message
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        let safeCategory = category.replacingOccurrences(of: LogEntry.fieldSeparator, with: "/")
        return "\(time)\(LogEntry.fieldSeparator)\(level.tag)\(LogEntry.fieldSeparator)\(safeCategory)\(LogEntry.fieldSeparator)\(safeMessage)"
    }

    /// 从落盘单行反序列化。格式不符时返回 `nil`（跳过该行，不抛错）。
    public static func parse(line: String) -> LogEntry? {
        let parts = line.components(separatedBy: fieldSeparator)
        // 至少需要 时间 | 等级 | 分类 | 消息 四段；消息内可能再次出现分隔符。
        guard parts.count >= 4 else { return nil }
        guard let date = timestampFormatter.date(from: parts[0]) else { return nil }
        guard let level = LogLevel.parse(parts[1]) else { return nil }
        let category = parts[2]
        let message = parts[3...].joined(separator: fieldSeparator)
        let unescaped = message
            .replacingOccurrences(of: "\\n", with: "\n")
        return LogEntry(
            timestamp: date,
            level: level,
            category: category,
            message: unescaped,
            file: "",
            function: "",
            line: 0
        )
    }

    /// 导出为人类可读多行格式（用于复制/分享）。
    public func exportedText() -> String {
        let time = LogEntry.exportFormatter.string(from: timestamp)
        var head = "[\(time)] [\(level.tag)] [\(category)]"
        if !file.isEmpty {
            head += " \(file):\(line) \(function)"
        }
        return "\(head) \(message)"
    }

    /// 文件内 `|` 分隔的时间戳格式：固定宽度、可直接字典序排序。
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = .current
        return f
    }()

    /// 导出/复制时使用的展示格式。
    static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = .current
        return f
    }()
}
