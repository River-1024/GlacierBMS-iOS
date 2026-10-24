import ANTuRideDomain
import Foundation

/// 进行中加速测试的崩溃检查点。与 AccelerationHistory 分目录保存：
/// 未完成记录不满足历史 JSON 校验，绝不能被 loadAll 当作历史读取。
/// 写入走串行后台队列，只保留最新快照；编码或写盘失败静默丢弃该次快照，
/// 不影响正在进行的测试（检查点只是崩溃兜底，不是第二份数据源）。
public struct AccelerationCheckpointStore {
    public enum RecoveryOutcome: Equatable {
        case none
        case record(AccelerationRecord)
        case corrupt
    }

    public static let recoveryEndReason = "进程退出，测试未完成（恢复自检查点）"

    public let fileURL: URL
    private let queue = DispatchQueue(label: "com.anturide.acceleration.checkpoint", qos: .utility)

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("AccelerationCheckpoint", isDirectory: true)
        self.fileURL = base.appendingPathComponent("in-progress.json", isDirectory: false)
    }

    /// 异步写最新快照；测试结束时由 clear() 删除，正常结束的记录不落检查点文件。
    public func write(_ record: AccelerationRecord) {
        let url = fileURL
        queue.async {
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 同步读取检查点并改写为中断记录；不删除文件——落盘成功后由调用方 clear()。
    /// 已不是进行中状态的残留文件直接清除；损坏文件清除并报告，不阻断启动。
    public func recover() -> RecoveryOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        do {
            let record = try JSONDecoder().decode(AccelerationRecord.self, from: Data(contentsOf: fileURL))
            guard record.isActive else {
                try? FileManager.default.removeItem(at: fileURL)
                return .none
            }
            let endedAt = record.endedAt ?? Date()
            return .record(record.interruptedForRecovery(endedAt: endedAt, reason: Self.recoveryEndReason))
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return .corrupt
        }
    }

    /// 恢复记录成功写入历史后删除检查点；失败时保留，下次启动重试。
    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}
