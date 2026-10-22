import Foundation

/// 实时活动更新节流策略（纯函数，可直接单测，不依赖 ActivityKit 运行环境）。
///
/// 为什么必须节流：BLE 是 1s 轮询、GPS 是 5m 采样，若 1:1 调用 `Activity.update`
/// 会迅速耗尽系统给单个活动的更新预算，表现为锁屏数字卡顿、变灰甚至活动被结束。
///
/// 规则优先级：
/// 1. 新鲜度 / 数据来源 / 充放电方向变化——立即推送，不受最小间隔限制。
/// 2. 未达最小间隔——不推送（运动 1s，静止 5s）。
/// 3. 达到最小间隔且任一指标越过阈值——推送。
public struct LiveActivityUpdatePolicy: Equatable, Sendable {
    public let movingMinimumInterval: TimeInterval
    public let stationaryMinimumInterval: TimeInterval
    public let stationarySpeedKmh: Double
    public let socThreshold: Double
    public let speedThresholdKmh: Double
    public let powerThresholdWatts: Double
    public let distanceThresholdMeters: Double

    public init(
        movingMinimumInterval: TimeInterval = 1,
        stationaryMinimumInterval: TimeInterval = 5,
        stationarySpeedKmh: Double = 1,
        socThreshold: Double = 0.5,
        speedThresholdKmh: Double = 1,
        powerThresholdWatts: Double = 50,
        distanceThresholdMeters: Double = 10
    ) {
        self.movingMinimumInterval = movingMinimumInterval
        self.stationaryMinimumInterval = stationaryMinimumInterval
        self.stationarySpeedKmh = stationarySpeedKmh
        self.socThreshold = socThreshold
        self.speedThresholdKmh = speedThresholdKmh
        self.powerThresholdWatts = powerThresholdWatts
        self.distanceThresholdMeters = distanceThresholdMeters
    }

    public func shouldPush(
        previous: RideActivityAttributes.ContentState?,
        next: RideActivityAttributes.ContentState,
        elapsedSeconds: TimeInterval
    ) -> Bool {
        guard let previous else { return true }
        // 状态语义变化必须立刻反映，否则锁屏会出现「数据过期但仍显示为实时」。
        if previous.freshness != next.freshness { return true }
        if previous.source != next.source { return true }
        if previous.isCharging != next.isCharging { return true }

        let isMoving = (next.speedKmh ?? 0) >= stationarySpeedKmh
        let minimumInterval = isMoving ? movingMinimumInterval : stationaryMinimumInterval
        guard elapsedSeconds.isFinite, elapsedSeconds >= minimumInterval else { return false }

        return exceeds(previous.socPercent, next.socPercent, threshold: socThreshold)
            || exceeds(previous.speedKmh, next.speedKmh, threshold: speedThresholdKmh)
            || exceeds(previous.powerWatts, next.powerWatts, threshold: powerThresholdWatts)
            || exceeds(previous.distanceMeters, next.distanceMeters, threshold: distanceThresholdMeters)
    }

    /// `nil` 与有值之间切换视为变化；非有限值一律视为变化（宁可多推一次，不留错误数字）。
    private func exceeds(_ old: Double?, _ new: Double?, threshold: Double) -> Bool {
        switch (old, new) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (old?, new?):
            guard old.isFinite, new.isFinite else { return true }
            return abs(new - old) >= threshold
        }
    }
}
