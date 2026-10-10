import Foundation
import os

/// 应用日志门面。策略为**双写**：
///
/// 1. **系统统一日志**（`os.Logger`）：真机不连 Xcode 时也可用 Console.app 抓取，
///    用于崩溃现场取证；携带 Apple 原生的隐私与性能优化。
/// 2. **沙盒文件**（`LogFileWriter`）：承载「查看 / 导出 / 清除 / 复制」等管理能力，
///    系统日志层不提供这些 API。
///
/// 调用点约定：使用 `AppLog.ble.info("...")` 这类静态分类入口，避免各处重复拼接 subsystem。
///
/// - Note: 本类型是 `Sendable` 的无状态门面；内部写入器自行串行化，可安全跨线程调用。
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()

    /// 运行时最低记录等级。低于该等级的日志既不入系统日志也不落盘。
    /// 变更会立即持久化到 `UserDefaults`，重启后保持。
    public private(set) var minimumLevel: LogLevel

    private let writer: LogFileWriter
    private let defaults: UserDefaults
    private let stateQueue = DispatchQueue(label: "com.zjsf.anturide.logging.state")

    static let minimumLevelDefaultsKey = "com.zjsf.anturide.log.minimumLevel"

    init(
        writer: LogFileWriter = LogFileWriter(),
        defaults: UserDefaults = .standard
    ) {
        self.writer = writer
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.minimumLevelDefaultsKey) as? Int
        self.minimumLevel = stored.flatMap(LogLevel.init(rawValue:)) ?? AppLog.defaultMinimumLevel
    }

    /// 默认等级：Debug 构建记录 `debug` 以上以便排查；Release 构建只记录 `notice` 以上，
    /// 避免高频细节拖慢线上性能并污染日志文件。
    static var defaultMinimumLevel: LogLevel {
        #if DEBUG
        return .debug
        #else
        return .notice
        #endif
    }

    /// 调整最低记录等级并持久化。
    /// - Parameter level: 新的阈值；等于阈值及以上的日志才会被记录。
    public func setMinimumLevel(_ level: LogLevel) {
        stateQueue.sync {
            minimumLevel = level
            defaults.set(level.rawValue, forKey: Self.minimumLevelDefaultsKey)
        }
    }

    /// 恢复为构建配置对应的默认等级。
    public func resetMinimumLevel() {
        setMinimumLevel(AppLog.defaultMinimumLevel)
    }

    // MARK: - 记录入口

    /// 核心写入口。通常不直接调用，优先使用下面带固定 category 的静态属性。
    func log(
        _ level: LogLevel,
        category: String,
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let threshold = stateQueue.sync { minimumLevel }
        guard level >= threshold else { return }

        let rendered = message()
        let source = AppLog.sourceFileName(file)

        // 1) 系统统一日志。grade 映射到 OSLog 的隐私/持久化语义。
        let logger = Logger(subsystem: AppLog.subsystem, category: category)
        logger.log(level: level.osLogType, "\(rendered, privacy: .public)")

        // 2) 沙盒文件。
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: rendered,
            file: source,
            function: function,
            line: line
        )
        writer.append(entry.serialized())
    }

    // MARK: - 分类入口

    /// 蓝牙链路。
    public static var ble: CategoryLogger { CategoryLogger(category: "ble") }
    /// 协议解析。
    public static var protocolParser: CategoryLogger { CategoryLogger(category: "protocol") }
    /// 界面交互。
    public static var ui: CategoryLogger { CategoryLogger(category: "ui") }
    /// 应用生命周期。
    public static var lifecycle: CategoryLogger { CategoryLogger(category: "lifecycle") }

    static let subsystem = "com.zjsf.anturide"

    /// 从 `#fileID`（形如 `ANTuRide/BmsBluetoothService.swift`）提取纯文件名。
    static func sourceFileName(_ fileID: String) -> String {
        fileID.split(separator: "/").last.map(String.init) ?? fileID
    }
}

/// 绑定固定 category 的日志入口。所有分类入口共享同一 `AppLog` 实例。
public struct CategoryLogger: Sendable {
    let category: String

    public func debug(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        AppLog.shared.log(.debug, category: category, message(), file: file, function: function, line: line)
    }

    public func info(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        AppLog.shared.log(.info, category: category, message(), file: file, function: function, line: line)
    }

    public func notice(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        AppLog.shared.log(.notice, category: category, message(), file: file, function: function, line: line)
    }

    public func warning(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        AppLog.shared.log(.warning, category: category, message(), file: file, function: function, line: line)
    }

    public func error(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        AppLog.shared.log(.error, category: category, message(), file: file, function: function, line: line)
    }

    public func fault(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        AppLog.shared.log(.fault, category: category, message(), file: file, function: function, line: line)
    }
}

extension LogLevel {
    /// 映射到 OSLog 的类型。`warning` 归入 `error` 语义族以在 Console.app 中高亮，
    /// 但落盘文件仍保留独立的 WARN 标签。
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error: return .error
        case .fault: return .fault
        }
    }
}
