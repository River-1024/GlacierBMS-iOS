import ANTuRideDomain
import Combine
import Foundation

/// 遥测数据来源。UI 与实时活动必须能区分本地直连与云端回填：
/// 两者的数据年龄和可信度不同，不能混为一谈。
public enum TelemetryOrigin: String, Equatable, Sendable {
    case none
    case local
    case remote
}

/// 链路状态。把 BLE 的细粒度状态归一化为消费端真正关心的三档，
/// 避免把 `BmsBluetoothService.State` 的具体枚举泄漏到其他服务与视图。
public enum TelemetryLinkState: Equatable, Sendable {
    case ready
    case connecting
    case unavailable
}

/// 数据可用性。**任何非 `localBLE` 的值都不得当作实时值展示**：
/// - `localStale`：本地有值但已超过新鲜窗口；
/// - `remote`：值来自云端，附带设备侧采集到现在的秒数；
/// - `offline`：完全没有可用值。
public enum TelemetryAvailability: Equatable, Sendable {
    case localBLE
    case localStale(ageSeconds: TimeInterval)
    case remote(ageSeconds: TimeInterval)
    case offline

    /// 只有本地新鲜数据可作为实时值。远程与过期数据一律为 false。
    public var isLive: Bool {
        if case .localBLE = self { return true }
        return false
    }

    /// 数据年龄；`localBLE` 与 `offline` 无有意义年龄。
    public var ageSeconds: TimeInterval? {
        switch self {
        case .localBLE, .offline: return nil
        case .localStale(let ageSeconds), .remote(let ageSeconds): return ageSeconds
        }
    }
}

/// 遥测来源抽象。当前只有 BLE 实现；接入远程数据源后
/// 由 `FusedTelemetrySource` 按「本地优先、远程兜底」合并。
///
/// 约束：`latestSnapshot` 的 `receivedAt` 必须是**设备侧采集时间**。
/// 远程回填若把接收时间当采集时间，会让新鲜度判定与行程能耗配对被欺骗。
@MainActor
public protocol TelemetrySource: AnyObject {
    var latestSnapshot: BmsSnapshot? { get }
    /// 注意 `@Published` 在赋值前发送：订阅方应直接消费事件参数，不回读属性。
    var snapshotPublisher: AnyPublisher<BmsSnapshot?, Never> { get }
    var linkState: TelemetryLinkState { get }
    var linkStatePublisher: AnyPublisher<TelemetryLinkState, Never> { get }
    var telemetryDeviceID: UUID? { get }
    /// 设备身份变化流。续航窗口按设备隔离，重连到另一台 BMS 必须能感知。
    var deviceIDPublisher: AnyPublisher<UUID?, Never> { get }
    var telemetryOrigin: TelemetryOrigin { get }
    var telemetryAvailability: TelemetryAvailability { get }
}

/// 后台遥测保持能力。仅由 `TripSessionService` 在行程开始/结束时调用：
/// 行程记录期间锁屏不再暂停采样，BLE 需要保留连接并继续周期查询。
@MainActor
public protocol BackgroundTelemetrySustaining: AnyObject {
    func setBackgroundTelemetrySustained(_ sustained: Bool)
}

extension BmsBluetoothService: TelemetrySource {
    public var snapshotPublisher: AnyPublisher<BmsSnapshot?, Never> {
        $latestSnapshot.eraseToAnyPublisher()
    }

    public var linkState: TelemetryLinkState {
        Self.normalizedLinkState(for: state)
    }

    public var linkStatePublisher: AnyPublisher<TelemetryLinkState, Never> {
        $state
            .map { Self.normalizedLinkState(for: $0) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public var telemetryDeviceID: UUID? { connectedDeviceID }

    public var deviceIDPublisher: AnyPublisher<UUID?, Never> {
        $connectedDeviceID.removeDuplicates().eraseToAnyPublisher()
    }

    public var telemetryOrigin: TelemetryOrigin { .local }

    /// 单机实现不做新鲜度判断：由融合器按快照年龄计算真实可用性。
    public var telemetryAvailability: TelemetryAvailability { .localBLE }

    static func normalizedLinkState(for state: State) -> TelemetryLinkState {
        switch state {
        case .ready:
            return .ready
        case .scanning, .connecting, .discovering, .reconnecting:
            return .connecting
        case .idle, .poweredOff, .disconnected:
            return .unavailable
        }
    }
}

/// 方法体在 `BmsBluetoothService` 内实现；此处必须显式声明遵循，
/// 否则 `telemetry as? BackgroundTelemetrySustaining` 恒为 nil，
/// 锁屏续记会静默失效且不产生任何编译错误。
extension BmsBluetoothService: BackgroundTelemetrySustaining {}
