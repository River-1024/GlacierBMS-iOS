import Foundation

/// 日志等级。语义对齐 Apple 统一日志（OSLog）的五级模型，
/// 并保证「等级可比较」以便运行时按阈值过滤。
///
/// 语义约定（不得混用）：
/// - `debug`   开发期细节，Release 构建应被剥离，不落盘。
/// - `info`    正常流程上下文（扫描启动、帧到达）。
/// - `notice`  重要业务事件（连接成功、通知开启、解析成功），默认持久化等级。
/// - `warning` 可继续运行但需要关注（帧被丢弃、数据过期）。
/// - `error`   操作失败（连接失败、解析失败、写入失败）。
/// - `fault`   不变量被破坏、本应不可能发生（索引越界防护触发、状态机非法迁移）。
public enum LogLevel: Int, Comparable, CaseIterable, Sendable, Codable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4
    case fault = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 面向界面的短标签。
    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }

    /// 中文说明，用于设置页向用户解释等级含义。
    public var localizedDescription: String {
        switch self {
        case .debug: return "调试细节，仅开发期记录"
        case .info: return "常规流程信息"
        case .notice: return "重要事件（连接、解析成功）"
        case .warning: return "需要关注但不中断"
        case .error: return "操作失败"
        case .fault: return "严重异常（本应不可能发生）"
        }
    }

    /// 解析落盘文件中记录的等级标签。兼容历史/别名写法。
    public static func parse(_ raw: String) -> LogLevel? {
        switch raw.uppercased() {
        case "DEBUG": return .debug
        case "INFO": return .info
        case "NOTICE", "DEFAULT": return .notice
        case "WARN", "WARNING": return .warning
        case "ERROR": return .error
        case "FAULT", "CRITICAL": return .fault
        default: return nil
        }
    }

    /// 建议的同级名称，用于文本导出的列对齐。
    public var tag: String { label }
}
