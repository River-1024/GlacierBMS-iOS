import Foundation

/// 业务角色与 BLE 外设身份分离；不使用可重名的设备名做主键。
public enum BluetoothDeviceRole: String, Codable, Sendable {
    case battery
    case controller
}

/// 仅控制候选列表，不替代连接后的服务/特征/协议验证。
public enum BluetoothDeviceNameFilter {
    public static func matches(_ name: String, role: BluetoothDeviceRole, enabled: Bool) -> Bool {
        guard enabled else { return true }
        let keyword = role == .battery ? "ant" : "apt"
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: keyword, options: [.caseInsensitive]) != nil
    }
}

/// 每次启动/真正进入前台各一次自动机会。用户断开比前台激活优先。
/// 只表达连接意愿；权限、协议校验、超时和 BLE 回调由服务处理。
public struct DeviceAutoConnectionPolicy: Sendable {
    public private(set) var consumed = false
    public private(set) var suppressedForRun = false

    public init() {}

    public mutating func beginForegroundSession() {
        consumed = suppressedForRun
    }

    public mutating func suppressForRun() {
        suppressedForRun = true
        consumed = true
    }

    public mutating func suppressForForegroundSession() {
        consumed = true
    }

    /// 显式连接/重试不受先前主动断开限制，但不额外触发同次自动连接。
    public mutating func allowManualConnection() {
        suppressedForRun = false
        consumed = true
    }

    public mutating func consumeTarget(poweredOn: Bool, enabled: Bool, rememberedID: UUID?, hasActiveSession: Bool) -> UUID? {
        guard poweredOn, !consumed, !suppressedForRun else { return nil }
        consumed = true
        return enabled && !hasActiveSession ? rememberedID : nil
    }
}

/// 两个独立 Central 的最小协调边界。Pending/retiring 会话也必须占用 UUID。
/// 不管理连接、数据或持久化；释放须由持有角色在会话真实结束后完成。
@MainActor
public final class BluetoothDeviceRegistry {
    public static let shared = BluetoothDeviceRegistry()
    private var owners: [UUID: BluetoothDeviceRole] = [:]

    public init() {}

    @discardableResult
    public func claim(_ id: UUID, for role: BluetoothDeviceRole) -> Bool {
        guard owners[id] == nil || owners[id] == role else { return false }
        owners[id] = role
        return true
    }

    public func release(_ id: UUID, for role: BluetoothDeviceRole) {
        guard owners[id] == role else { return }
        owners.removeValue(forKey: id)
    }

    public func releaseAll(for role: BluetoothDeviceRole) {
        owners = owners.filter { $0.value != role }
    }

    public func owner(of id: UUID) -> BluetoothDeviceRole? { owners[id] }
}
