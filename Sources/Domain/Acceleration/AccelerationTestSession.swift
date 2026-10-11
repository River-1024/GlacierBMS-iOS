import Foundation

/// 单一所有者的纯领域会话；只接收安卓控制器 RPM 转速换算样本。
/// 计时使用单调时钟，墙钟只用于记录日期。
public final class AccelerationTestSession {
    public let config: AccelerationConfig
    public static let maximumSamples = 20_000

    private final class Channel {
        let source: AccelerationSource
        var state: AccelerationChannelState
        var reason: String?
        var previous: AccelerationSpeedSample?
        var firstTimestamp: TimeInterval?
        var stillSince: TimeInterval?
        var lastStill: AccelerationSpeedSample?
        var departure: [AccelerationSpeedSample] = []
        var startTimestamp: TimeInterval?
        var uncertaintyMs: Double?
        var distanceMeters = 0.0
        var sampleCount = 0
        var maxGap = 0.0
        var rejectedSampleCount = 0
        var lastQualityWarning: String?
        var splits: [AccelerationSplit] = []
        var pending: [Int: PendingSplit] = [:]
        var movementFirst: TimeInterval?
        var movementSamples = 0

        init(source: AccelerationSource, available: Bool) {
            self.source = source
            state = available ? .waitingStill : .unavailable
            reason = available ? nil : "渠道不可用"
        }
        var accepting: Bool { state.isAccepting }
    }

    private struct PendingSplit {
        let index: Int
        let targetKmh: Double
        let crossedAt: TimeInterval
        let distance: Double
        let firstAbove: TimeInterval
        var confirmingSamples = 1
        var confirmed = false
    }

    private var channels: [Channel] = []
    private var id = ""
    private var startedAt: Date?
    private var referenceTimestamp: TimeInterval = 0
    private var phase: AccelerationPhase = .armed
    private var endedAt: Date?
    private var endReason: String?
    private var speedSamples: [AccelerationSpeedSample] = []
    private var currentSamples: [AccelerationCurrentSample] = []
    private var lastCurrentTimestamp: TimeInterval?
    private var currentSequences: Set<Int64> = []
    private var lastTick: TimeInterval?
    private var conditions: [String: String] = [:]

    /// RPM 外设已由上层控制器服务确认后创建会话；领域层只接受 RPM。
    public init(config: AccelerationConfig = AccelerationConfig()) {
        self.config = config
    }

    public var isActive: Bool { startedAt != nil && phase.isActive }

    public var record: AccelerationRecord? {
        guard let startedAt = startedAt else { return nil }
        return AccelerationRecord(id: id, startedAt: startedAt, referenceTimestamp: referenceTimestamp,
            config: config, phase: phase, endedAt: endedAt, endReason: endReason,
            results: channels.map { channel in
                let elapsed = (channel.previous?.timestamp ?? 0) - (channel.firstTimestamp ?? 0)
                return AccelerationChannelResult(source: channel.source, state: channel.state,
                    startTimestamp: channel.startTimestamp, startUncertaintyMs: channel.uncertaintyMs,
                    splits: channel.splits, reason: channel.reason, sampleCount: channel.sampleCount,
                    effectiveHz: elapsed > 0 ? Double(channel.sampleCount - 1) / elapsed : 0,
                    maxGapMs: channel.maxGap * 1_000, rejectedSampleCount: channel.rejectedSampleCount,
                    lastQualityWarning: channel.lastQualityWarning)
            }, speedSamples: speedSamples, currentSamples: currentSamples,
            conditions: conditions)
    }

    @discardableResult
    public func start(at timestamp: TimeInterval, date: Date = Date(),
                      id: String = UUID().uuidString, conditions: [String: String] = [:]) throws -> AccelerationRecord {
        try config.validate()
        guard timestamp.isFinite, timestamp >= 0, date.timeIntervalSince1970.isFinite else {
            throw AccelerationError.invalidTimestamp
        }
        guard !isActive else { throw AccelerationError.sessionAlreadyActive }
        reset()
        self.id = id
        startedAt = date
        referenceTimestamp = timestamp
        self.conditions = conditions
        // 产品范围固定为 RPM 单渠道；保留旧参数仅为旧调用编译兼容，其他值忽略。
        channels = [Channel(source: .rpm, available: true)]
        finishIfSettled(at: timestamp)
        // start always establishes a record, even when every source is unavailable.
        return record!
    }

    /// Explicitly discards the current run; the service must save its snapshot first.
    public func reset() {
        channels.removeAll()
        id = ""
        startedAt = nil
        referenceTimestamp = 0
        phase = .armed
        endedAt = nil
        endReason = nil
        speedSamples.removeAll()
        currentSamples.removeAll()
        currentSequences.removeAll()
        lastCurrentTimestamp = nil
        lastTick = nil
        conditions.removeAll()
    }

    /// RPM 样本时间必须是原始单调测量时间；receivedAt 仅保留旧接口兼容，不参与 GPS 判断。
    public func ingest(_ sample: AccelerationSpeedSample, receivedAt: TimeInterval? = nil) {
        guard isActive, let channel = channel(sample.source), channel.accepting else { return }
        guard sample.timestamp.isFinite, sample.timestamp >= referenceTimestamp,
              channel.previous.map({ sample.timestamp > $0.timestamp }) ?? true else {
            reject(channel, "重复、乱序或会话开始前的时间戳")
            return
        }
        if !sample.quality.isValid || sample.quality.timingAmbiguous || sample.quality.isMock {
            invalidate(sample.source, reason: sample.quality.reason ?? "RPM 样本质量或原始帧时序不可信", at: sample.timestamp)
            return
        }
        guard sample.speedMps.isFinite, sample.speedKmh.isFinite,
              sample.accelerationMps2.map({ $0.isFinite }) ?? true,
              true else {
            invalidate(sample.source, reason: "速度、加速度或质量包含非有限/非法数据", at: sample.timestamp)
            return
        }
        let previous = channel.previous
        let gap = previous.map { sample.timestamp - $0.timestamp } ?? 0
        channel.maxGap = max(channel.maxGap, gap)
        if let previous = previous, sample.timestamp > previous.timestamp + gapLimit(sample.source) {
            invalidate(sample.source, reason: "采样间隙超限，禁止跨缺样插值", at: sample.timestamp)
            return
        }
        guard reserveSample(at: sample.timestamp) else { return }
        checkTimeouts(at: sample.timestamp)
        guard isActive, channel.accepting else { return }
        guard sample.speedKmh > -1 else {
            invalidate(sample.source, reason: "明显反向运动，速度为负", at: sample.timestamp)
            return
        }
        speedSamples.append(sample)
        channel.sampleCount += 1
        if channel.firstTimestamp == nil { channel.firstTimestamp = sample.timestamp }
        channel.previous = sample
        switch channel.state {
        case .waitingStill:
            if abs(sample.speedKmh) <= 0.3 {
                if channel.stillSince == nil { channel.stillSince = sample.timestamp }
                channel.lastStill = sample
                if sample.timestamp >= channel.stillSince! + 2 { channel.state = .ready }
            } else {
                channel.stillSince = nil
                channel.lastStill = nil
            }
        case .ready: acceptDeparture(channel, sample)
        case .running:
            if let previous = previous { integrate(channel, previous, sample) }
        default: break
        }
        finishIfSettled(at: sample.timestamp)
    }

    private func acceptDeparture(_ channel: Channel, _ sample: AccelerationSpeedSample) {
        if sample.speedKmh <= 0.3 {
            clearDeparture(channel)
            channel.lastStill = abs(sample.speedKmh) <= 0.3 ? sample : nil
            return
        }
        guard let lastStill = channel.lastStill else {
            channel.state = .waitingStill
            channel.stillSince = nil
            clearDeparture(channel)
            return
        }
        channel.departure.append(sample)
        if sample.speedKmh < 1 {
            channel.movementFirst = nil
            channel.movementSamples = 0
            return
        }
        if channel.movementFirst == nil { channel.movementFirst = sample.timestamp }
        channel.movementSamples += 1
        guard channel.movementSamples >= 2, sample.timestamp >= channel.movementFirst! + 0.02 else { return }
        channel.startTimestamp = lastStill.timestamp
        channel.uncertaintyMs = (channel.departure[0].timestamp - lastStill.timestamp) * 1_000
        channel.state = .running
        phase = .running
        var left = lastStill
        for right in channel.departure {
            integrate(channel, left, right)
            left = right
            if !channel.accepting { break }
        }
        clearDeparture(channel)
    }

    private func integrate(_ channel: Channel, _ left: AccelerationSpeedSample, _ right: AccelerationSpeedSample) {
        let duration = right.timestamp - left.timestamp
        let before = channel.distanceMeters
        for index in Array(channel.pending.keys) {
            guard var candidate = channel.pending[index] else { continue }
            if right.speedKmh < candidate.targetKmh {
                channel.pending.removeValue(forKey: index)
            } else {
                candidate.confirmingSamples += 1
                candidate.confirmed = candidate.confirmingSamples >= 2 && right.timestamp >= candidate.firstAbove + 0.02
                channel.pending[index] = candidate
            }
        }
        let targets = config.targetsKmh
        for index in channel.splits.count..<targets.count {
            let target = targets[index]
            guard channel.pending[index] == nil, left.speedKmh < target, right.speedKmh >= target else { continue }
            let ratio = (target - left.speedKmh) / (right.speedKmh - left.speedKmh)
            let crossedAt = left.timestamp + duration * ratio
            let distance = before + (left.speedMps / 2 + target / 3.6 / 2) * duration * ratio
            guard distance.isFinite else {
                invalidate(channel.source, reason: "距离积分出现非有限结果", at: right.timestamp)
                return
            }
            channel.pending[index] = PendingSplit(index: index, targetKmh: target,
                crossedAt: crossedAt, distance: distance, firstAbove: right.timestamp)
        }
        while let candidate = channel.pending[channel.splits.count], candidate.confirmed {
            channel.pending.removeValue(forKey: channel.splits.count)
            let elapsed = candidate.crossedAt - channel.startTimestamp!
            channel.splits.append(AccelerationSplit(targetSpeedKmh: candidate.targetKmh,
                crossedAt: candidate.crossedAt, cumulativeSeconds: elapsed,
                segmentSeconds: elapsed - (channel.splits.last?.cumulativeSeconds ?? 0), distanceMeters: candidate.distance))
            if candidate.index == targets.count - 1 {
                channel.distanceMeters = candidate.distance
                channel.state = .reached
                return
            }
        }
        channel.distanceMeters += (left.speedMps / 2 + right.speedMps / 2) * duration
        if !channel.distanceMeters.isFinite {
            invalidate(channel.source, reason: "距离积分出现非有限结果", at: right.timestamp)
        }
    }

    /// 电流是独立记录证据，不参与 RPM 速度修正。保留符号与时序标记。
    /// Current is independent evidence, never a speed correction. Preserve signed
    /// current and ambiguous multi-frame batches without inventing speed timestamps.
    public func ingest(_ sample: AccelerationCurrentSample) {
        let trailing = sample.timingAmbiguous && startedAt != nil && phase == .partial && channel(.rpm)?.state == .invalid
        guard isActive || trailing else { return }
        guard sample.busCurrentA.isFinite, sample.phasePeakCurrentA.isFinite else {
            conditions["电流质量"] = "拒绝非有限电流样本"
            return
        }
        guard sample.timestamp.isFinite, sample.timestamp >= referenceTimestamp,
              lastCurrentTimestamp.map({ sample.timestamp >= $0 }) ?? true,
              sample.sequence == 0 || !currentSequences.contains(sample.sequence),
              reserveSample(at: sample.timestamp) else { return }
        if isActive { checkTimeouts(at: sample.timestamp) }
        guard isActive || trailing else { return }
        lastCurrentTimestamp = sample.timestamp
        if sample.sequence != 0 { currentSequences.insert(sample.sequence) }
        currentSamples.append(sample)
    }

    public func setCondition(_ key: String, value: String) {
        if isActive { conditions[key] = value }
    }

    public func invalidate(_ source: AccelerationSource, reason: String, at timestamp: TimeInterval? = nil) {
        guard isActive, let channel = channel(source), channel.accepting else { return }
        markInvalid(channel, reason)
        let now = timestamp.flatMap { $0.isFinite && $0 >= referenceTimestamp ? $0 : nil } ?? latestTimestamp
        finishIfSettled(at: now)
    }

    /// Silence watchdog；tick 不会伪造静止、起步或目标穿越。
    public func tick(at timestamp: TimeInterval) {
        guard isActive, timestamp.isFinite, timestamp >= referenceTimestamp,
              lastTick.map({ timestamp >= $0 }) ?? true else { return }
        lastTick = timestamp
        checkTimeouts(at: timestamp)
        guard isActive else { return }
        for channel in channels where channel.accepting {
            if let previous = channel.previous, timestamp > previous.timestamp + gapLimit(channel.source) {
                markInvalid(channel, "测速数据中断，采样间隙超限")
            }
        }
        finishIfSettled(at: timestamp)
    }

    @discardableResult
    public func finish(at timestamp: TimeInterval, reason: String = "用户结束", interrupted: Bool = false) -> AccelerationRecord? {
        guard isActive, timestamp.isFinite, timestamp >= referenceTimestamp else { return record }
        let reached = channels.contains { $0.state == .reached }
        let allReached = channels.allSatisfy { $0.state == .unavailable || $0.state == .reached }
        phase = interrupted ? .interrupted : (allReached && reached ? .completed : .partial)
        for channel in channels where channel.accepting { markInvalid(channel, "未达到目标：\(reason)") }
        endedAt = epochAt(max(timestamp, latestTimestamp))
        endReason = reason
        return record
    }

    public func state(for source: AccelerationSource) -> AccelerationChannelState? { channel(source)?.state }

    public func stillnessFraction(for source: AccelerationSource, at timestamp: TimeInterval) -> Double {
        guard timestamp.isFinite, let since = channel(source)?.stillSince, timestamp > since else { return 0 }
        return min(1, (timestamp - since) / 2)
    }

    private func channel(_ source: AccelerationSource) -> Channel? { channels.first { $0.source == source } }
    private var latestTimestamp: TimeInterval {
        max(referenceTimestamp, max(channels.compactMap { $0.previous?.timestamp }.max() ?? referenceTimestamp,
                                     lastCurrentTimestamp ?? referenceTimestamp))
    }
    private func epochAt(_ timestamp: TimeInterval) -> Date {
        startedAt!.addingTimeInterval(max(0, timestamp - referenceTimestamp))
    }
    private func gapLimit(_ source: AccelerationSource) -> TimeInterval {
        // 安卓 RPM 渠道的最大允许采样间隔。
        return 0.5
    }
    private func reject(_ channel: Channel, _ reason: String) {
        channel.rejectedSampleCount += 1
        channel.lastQualityWarning = reason
    }
    private func clearDeparture(_ channel: Channel) {
        channel.departure.removeAll()
        channel.movementFirst = nil
        channel.movementSamples = 0
    }
    private func markInvalid(_ channel: Channel, _ reason: String) {
        guard channel.accepting else { return }
        channel.state = .invalid
        channel.reason = reason
        clearDeparture(channel)
        channel.pending.removeAll()
    }
    private func checkTimeouts(at timestamp: TimeInterval) {
        for channel in channels where channel.accepting {
            if let start = channel.startTimestamp {
                if timestamp >= start + 60 { markInvalid(channel, "进行中超过 60 秒，未达到目标") }
            } else if timestamp >= referenceTimestamp + 30 {
                markInvalid(channel, "等待起步超过 30 秒")
            }
        }
        finishIfSettled(at: timestamp)
    }
    private func reserveSample(at timestamp: TimeInterval) -> Bool {
        guard speedSamples.count + currentSamples.count < Self.maximumSamples else {
            for channel in channels where channel.accepting { markInvalid(channel, "样本数量达到硬上限 20000") }
            finishIfSettled(at: timestamp)
            return false
        }
        return true
    }
    private func finishIfSettled(at timestamp: TimeInterval) {
        if isActive && !channels.contains(where: { $0.accepting }) {
            finish(at: timestamp, reason: channels.contains { $0.state == .reached }
                   ? "有用渠道均已达到目标或失效" : "所有测速渠道不可用或失效")
        }
    }
}
