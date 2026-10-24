import Foundation

extension AccelerationRecord {
    /// 检查点恢复：进行中的快照只能改写为"已中断"证据落盘。
    /// 单调接收时钟不能跨启动复用，恢复后的记录永不可续测。
    public func interruptedForRecovery(endedAt: Date, reason: String) -> AccelerationRecord {
        AccelerationRecord(id: id, startedAt: startedAt, referenceTimestamp: referenceTimestamp,
                           config: config, phase: .interrupted, endedAt: endedAt, endReason: reason,
                           results: results, speedSamples: speedSamples, currentSamples: currentSamples,
                           conditions: conditions)
    }
}
