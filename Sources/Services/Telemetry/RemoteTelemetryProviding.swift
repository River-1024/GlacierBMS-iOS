import ANTuRideDomain
import Foundation

/// 云端回填的一次遥测结果。
///
/// 约定：`snapshot.receivedAt` 必须等于 `capturedAt`（设备侧采集时间），
/// 不要填本机接收时间。这样 `BmsFreshnessEvaluator` 会把远程数据判为过期，
/// `TripRecorder` 也会因配对间隔超限跳过它——远程数据不会污染实时指标与能耗积分。
public struct RemoteTelemetry: Equatable, Sendable {
    public let snapshot: BmsSnapshot
    public let capturedAt: Date
    public let fetchedAt: Date
    public let deviceID: UUID?

    /// 超过此年龄的远程值不再作为可展示数据，避免锁屏上出现几小时前的电量。
    public static let maxAcceptableAge: TimeInterval = 120

    public init(snapshot: BmsSnapshot, capturedAt: Date, fetchedAt: Date = Date(), deviceID: UUID? = nil) {
        self.snapshot = snapshot
        self.capturedAt = capturedAt
        self.fetchedAt = fetchedAt
        self.deviceID = deviceID
    }

    public var ageSeconds: TimeInterval {
        max(0, fetchedAt.timeIntervalSince(capturedAt))
    }

    public var isAcceptable: Bool {
        ageSeconds.isFinite && ageSeconds <= Self.maxAcceptableAge
    }
}

/// 远程遥测按需拉取。
///
/// 按产品约定，远程是**兜底**而非并行数据源：
/// 本地 BLE 有新鲜数据时不会调用本协议；只有本地无数据或已过期时才请求一次，
/// 且由融合器施加冷却间隔。因此实现方不需要维持长连接或订阅。
public protocol RemoteTelemetryProviding: Sendable {
    func fetchLatest() async throws -> RemoteTelemetry?
}

/// 未接入远程链路时的占位实现。融合器据此退化为纯本地行为。
public struct DisabledRemoteTelemetryProvider: RemoteTelemetryProviding {
    public init() {}
    public func fetchLatest() async throws -> RemoteTelemetry? { nil }
}
