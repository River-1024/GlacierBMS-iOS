import Foundation

/// BMS 数据新鲜度。阶段 1 约束：不得用陈旧值伪装实时值，
/// 超出新鲜窗口的数据必须显式标记为过期。
public struct BmsDataFreshness: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case noData
        case fresh
        case stale
    }

    public let level: Level
    public let ageSeconds: Double?

    public static let noData = BmsDataFreshness(level: .noData, ageSeconds: nil)

    public init(level: Level, ageSeconds: Double?) {
        self.level = level
        self.ageSeconds = ageSeconds
    }
}

/// 按接收时间评估快照新鲜度，纯函数、无副作用，便于单元测试。
public struct BmsFreshnessEvaluator: Sendable {
    public let freshWindow: TimeInterval

    public init(freshWindow: TimeInterval = 5) {
        self.freshWindow = freshWindow
    }

    public func evaluate(snapshot: BmsSnapshot?, now: Date = Date()) -> BmsDataFreshness {
        guard let snapshot else { return .noData }
        let age = max(0, now.timeIntervalSince(snapshot.receivedAt))
        let level: BmsDataFreshness.Level = age <= freshWindow ? .fresh : .stale
        return BmsDataFreshness(level: level, ageSeconds: age)
    }
}
