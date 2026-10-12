import Foundation

/// 一段线性变化的电气遥测。正功率为放电，负功率为再生；电流保留原始符号。
public struct RangeElectricalSpan: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let startPowerW: Double
    public let endPowerW: Double
    public let startCurrentA: Double
    public let endCurrentA: Double

    public init(startedAt: Date, endedAt: Date, startPowerW: Double, endPowerW: Double,
                startCurrentA: Double, endCurrentA: Double) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPowerW = startPowerW
        self.endPowerW = endPowerW
        self.startCurrentA = startCurrentA
        self.endCurrentA = endCurrentA
    }

    public var netWh: Double { dischargeWh - regenerationWh }
    public var dischargeWh: Double { positiveIntegral(startPowerW, endPowerW) }
    public var regenerationWh: Double { positiveIntegral(-startPowerW, -endPowerW) }
    public var netAh: Double {
        (startCurrentA * 0.5 + endCurrentA * 0.5) * (duration / 3_600)
    }

    /// 返回交集，并先插值端点再积分；不按原始正负能量比例缩放。
    public func clipped(start: Date, end: Date) -> Self? {
        guard isWellFormed, Self.validBounds(start, end) else { return nil }
        let lower = max(startedAt, start)
        let upper = min(endedAt, end)
        guard lower < upper else { return nil }
        let startFraction = lower.timeIntervalSince(startedAt) / duration
        let endFraction = upper.timeIntervalSince(startedAt) / duration
        return Self(startedAt: lower, endedAt: upper,
                    startPowerW: interpolated(startPowerW, endPowerW, startFraction),
                    endPowerW: interpolated(startPowerW, endPowerW, endFraction),
                    startCurrentA: interpolated(startCurrentA, endCurrentA, startFraction),
                    endCurrentA: interpolated(startCurrentA, endCurrentA, endFraction))
    }

    fileprivate var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    fileprivate var isWellFormed: Bool {
        Self.validBounds(startedAt, endedAt) && duration.isFinite
            && startPowerW.isFinite && endPowerW.isFinite
            && startCurrentA.isFinite && endCurrentA.isFinite
            && netWh.isFinite && dischargeWh.isFinite && regenerationWh.isFinite && netAh.isFinite
    }

    fileprivate static func validBounds(_ start: Date, _ end: Date) -> Bool {
        start.timeIntervalSinceReferenceDate.isFinite
            && end.timeIntervalSinceReferenceDate.isFinite && start < end
    }

    private func interpolated(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        if fraction == 0 { return start }
        if fraction == 1 { return end }
        return start * (1 - fraction) + end * fraction
    }

    /// 零点两侧分别积分三角形。缩放后求比例，避免有限端点相加溢出。
    private func positiveIntegral(_ start: Double, _ end: Double) -> Double {
        let hours = duration / 3_600
        if start >= 0 && end >= 0 { return (start * 0.5 + end * 0.5) * hours }
        if start <= 0 && end <= 0 { return 0 }
        let positive = max(start, end)
        let negativeMagnitude = -min(start, end)
        let scale = max(positive, negativeMagnitude)
        let fraction = (positive / scale) / (positive / scale + negativeMagnitude / scale)
        return (positive * 0.5) * (hours * fraction)
    }
}

/// 一个有完整电气覆盖的行驶区间；构造不校验，窗口入口负责拒绝无效遥测。
public struct RangeDrivingInterval: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let distanceMeters: Double
    public let electricalSpans: [RangeElectricalSpan]
    /// BMS 前后剩余 Ah 的差值；未提供时仅兼容旧调用的电流积分。
    public let measuredNetAh: Double?

    public init(startedAt: Date, endedAt: Date, distanceMeters: Double,
                electricalSpans: [RangeElectricalSpan], netAh: Double? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.electricalSpans = electricalSpans
        self.measuredNetAh = netAh
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var netWh: Double { electricalSpans.reduce(0) { $0 + $1.netWh } }
    public var dischargeWh: Double { electricalSpans.reduce(0) { $0 + $1.dischargeWh } }
    public var regenerationWh: Double { electricalSpans.reduce(0) { $0 + $1.regenerationWh } }
    public var netAh: Double {
        measuredNetAh ?? electricalSpans.reduce(0) { $0 + $1.netAh }
    }

    /// 距离按时间比例缩放，电气数据逐段裁剪并重新积分。
    public func clipped(start: Date, end: Date) -> Self? {
        guard isWellFormed, RangeElectricalSpan.validBounds(start, end) else { return nil }
        let lower = max(startedAt, start)
        let upper = min(endedAt, end)
        guard lower < upper else { return nil }
        return Self(startedAt: lower, endedAt: upper,
                    distanceMeters: distanceMeters * (upper.timeIntervalSince(lower) / duration),
                    electricalSpans: electricalSpans.compactMap { $0.clipped(start: lower, end: upper) },
                    netAh: measuredNetAh.map { $0 * (upper.timeIntervalSince(lower) / duration) })
    }

    fileprivate var isWellFormed: Bool {
        guard RangeElectricalSpan.validBounds(startedAt, endedAt), duration.isFinite,
              distanceMeters.isFinite, distanceMeters >= 0,
              measuredNetAh.map({ $0.isFinite }) ?? true, !electricalSpans.isEmpty else {
            return false
        }
        var cursor = startedAt
        for span in electricalSpans {
            guard span.isWellFormed, span.startedAt == cursor, span.endedAt <= endedAt else {
                return false
            }
            cursor = span.endedAt
        }
        return cursor == endedAt && netWh.isFinite && dischargeWh.isFinite
            && regenerationWh.isFinite && netAh.isFinite
    }
}

/// 仅按累计有效行驶时长维护 FIFO；停车与现实时间流逝不推进或淘汰窗口。
public struct RangeDrivingWindow: Sendable {
    public static let maximumIntervalDuration: TimeInterval = 10
    public static let maximumIntervalDistanceMeters: Double = 2_000
    public static let minimumAverageSpeedKmh: Double = 3
    public static let minimumPredictionDuration: TimeInterval = 30
    public static let minimumPredictionDistanceMeters: Double = 200
    public static let minimumPredictionDischargeWh: Double = 5
    public static let minimumPredictionNetWh: Double = 5

    public private(set) var intervals: [RangeDrivingInterval] = []

    public init() {}

    /// 失败时不改变窗口。允许区间之间停车，但不允许重复、重叠或倒序。
    @discardableResult
    public mutating func append(_ interval: RangeDrivingInterval) -> Bool {
        guard interval.isWellFormed, interval.duration <= Self.maximumIntervalDuration,
              interval.distanceMeters <= Self.maximumIntervalDistanceMeters,
              interval.distanceMeters >= interval.duration * (Self.minimumAverageSpeedKmh / 3.6),
              intervals.last.map({ interval.startedAt >= $0.endedAt }) ?? true else {
            return false
        }
        let total = summary
        guard (total.duration + interval.duration).isFinite,
              (total.distanceMeters + interval.distanceMeters).isFinite,
              (total.netWh + interval.netWh).isFinite,
              (total.dischargeWh + interval.dischargeWh).isFinite,
              (total.regenerationWh + interval.regenerationWh).isFinite,
              (total.netAh + interval.netAh).isFinite else { return false }
        intervals.append(interval)
        return true
    }

    /// 保留最新的累计有效时长；部分首段按比例裁距并重新积分。
    /// 非有限目标不修改窗口，零或负目标清空窗口。
    public mutating func trim(to duration: TimeInterval) {
        guard duration.isFinite else { return }
        guard duration > 0 else { clear(); return }
        var excess = summary.duration - duration
        while excess > 0, let first = intervals.first {
            if excess >= first.duration {
                excess -= first.duration
                intervals.removeFirst()
            } else {
                let start = first.endedAt.addingTimeInterval(-(first.duration - excess))
                if let clipped = first.clipped(start: start, end: first.endedAt) {
                    intervals[0] = clipped
                } else {
                    // 目标时长小于 Date 的可表示精度时不保留零长段。
                    intervals.removeFirst()
                }
                break
            }
        }
    }

    public mutating func clear() { intervals.removeAll() }

    public var summary: (duration: TimeInterval, distanceMeters: Double, netWh: Double,
                         dischargeWh: Double, regenerationWh: Double, netAh: Double) {
        var result = (duration: 0.0, distanceMeters: 0.0, netWh: 0.0,
                      dischargeWh: 0.0, regenerationWh: 0.0, netAh: 0.0)
        for interval in intervals {
            result.duration += interval.duration
            result.distanceMeters += interval.distanceMeters
            result.netWh += interval.netWh
            result.dischargeWh += interval.dischargeWh
            result.regenerationWh += interval.regenerationWh
            result.netAh += interval.netAh
        }
        return result
    }

    // Service 可直接读取单项汇总；summary 为需要多项时的一次遍历入口。
    public var duration: TimeInterval { summary.duration }
    public var distanceMeters: Double { summary.distanceMeters }
    public var netWh: Double { summary.netWh }
    public var dischargeWh: Double { summary.dischargeWh }
    public var regenerationWh: Double { summary.regenerationWh }
    public var netAh: Double { summary.netAh }

    public var predictionStatus: RangePredictionStatus {
        guard !intervals.isEmpty else { return .noValidIntervals }
        let total = summary
        guard total.duration >= Self.minimumPredictionDuration,
              total.distanceMeters >= Self.minimumPredictionDistanceMeters,
              total.dischargeWh >= Self.minimumPredictionDischargeWh else { return .accumulating }
        guard total.netWh >= Self.minimumPredictionNetWh else { return .nonPositiveNetEnergy }
        return .valid
    }
}
