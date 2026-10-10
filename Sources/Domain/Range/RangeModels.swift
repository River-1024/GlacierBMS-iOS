import Foundation

/// 基础预测阶段使用的状态；它与 Android 完整模型的状态集合保持可映射，
/// 但本文件不实现 RangePredictionEngine/RangeEnergyEngine 的窗口维护或校准恢复。
public enum RangePredictionStatus: String, Equatable, Codable, Sendable, CaseIterable {
    case valid
    case telemetryStale
    case noValidIntervals
    case charging
    case capacityInvalid
    case undervoltage
    case disconnected
    case nonPositiveNetEnergy
    case accumulating

    /// 面向 UI 的稳定、非空中文原因文本。
    public var reason: String {
        switch self {
        case .valid: return "有效行驶窗口的基础续航估计"
        case .telemetryStale: return "遥测数据已过期"
        case .noValidIntervals: return "没有有效的行驶能耗区间"
        case .charging: return "充电期间不预测续航"
        case .capacityInvalid: return "容量或有效 Wh/Ah 无效"
        case .undervoltage: return "欠压期间不预测续航"
        case .disconnected: return "设备未连接"
        case .nonPositiveNetEnergy: return "窗口净耗电必须大于零"
        case .accumulating: return "正在积累行驶能耗窗口"
        }
    }
}

/// 设置由调用方按设备保存；领域模型不读取偏好设置或访问设备。
public struct RangeSettings: Equatable, Codable, Sendable {
    public let nominalCapacityAh: Double
    public let deviceID: String

    public init(nominalCapacityAh: Double, deviceID: String) {
        self.nominalCapacityAh = nominalCapacityAh
        self.deviceID = deviceID
    }
}

/// 基础预测结果。
///
/// `predictedRangeKm == nil` 表示当前不能安全预测；不会用 0 或上次结果冒充有效续航。
public struct RangePrediction: Equatable, Sendable {
    public let predictedRangeKm: Double?
    /// 稳定的机器可读原因；UI 不应解析中文文案来判断状态。
    public let reason: RangePredictionStatus

    public init(predictedRangeKm: Double?, reason: RangePredictionStatus) {
        self.predictedRangeKm = predictedRangeKm
        self.reason = reason
    }

    /// 便于调用方按传统 status 字段接入 UI。
    public var status: RangePredictionStatus { reason }

    /// 便于调用方按 Android 语义命名，不必复制映射。
    public var stopReason: RangePredictionStatus { reason }

    /// UI 可直接展示的非空原因文案。
    public var reasonText: String { reason.reason }
}

/// 纯、无状态的基础续航预测器。
///
/// 这是 Android 完整算法的基础接口与保守计算层，不是完整复刻：不维护有效区间，
/// 不实现 RangeEnergyEngine 的能耗窗口/缺口处理，也不实现 BatteryEnergyCalibration 的
/// 学习、持久化和恢复。调用方应先把同一设备的有效行驶窗口汇总成正的 `netWh` 与
/// `distanceMeters`，不要把停车、充电、缺口或无效采样合并进来。
public struct BasicRangePredictor: Sendable {
    public static let effectiveWhPerAhBounds: ClosedRange<Double> = 66...86

    public let settings: RangeSettings
    /// 未提供测量校准时使用保守下界 66 Wh/Ah；这不是实时电压测量值。
    public let effectiveWhPerAh: Double

    public init(settings: RangeSettings, effectiveWhPerAh: Double = 66) {
        self.settings = settings
        self.effectiveWhPerAh = effectiveWhPerAh
    }

    /// 使用剩余 Ah、有效窗口净 Wh、有效窗口距离计算基础续航。
    public func predict(
        remainingAh: Double,
        netWh: Double,
        distanceMeters: Double,
        remainingEnergyWh: Double? = nil,
        stale: Bool = false,
        disconnected: Bool = false,
        charging: Bool = false,
        undervoltage: Bool = false
    ) -> RangePrediction {
        // 多个停止条件同时出现时，按连接、新鲜度、充电、欠压的顺序给出原因。
        if disconnected { return unavailable(.disconnected) }
        if stale { return unavailable(.telemetryStale) }
        if charging { return unavailable(.charging) }
        if undervoltage { return unavailable(.undervoltage) }

        guard settings.nominalCapacityAh.isFinite, settings.nominalCapacityAh > 0,
              remainingAh.isFinite, remainingAh >= 0,
              remainingAh <= settings.nominalCapacityAh,
              effectiveWhPerAh.isFinite,
              Self.effectiveWhPerAhBounds.contains(effectiveWhPerAh) else {
            return unavailable(.capacityInvalid)
        }
        guard distanceMeters.isFinite, distanceMeters >= 0, netWh.isFinite else {
            return unavailable(.noValidIntervals)
        }
        if distanceMeters == 0 && netWh == 0 { return unavailable(.accumulating) }
        guard distanceMeters > 0 else { return unavailable(.noValidIntervals) }
        guard netWh > 0 else { return unavailable(.nonPositiveNetEnergy) }

        let distanceKm = distanceMeters / 1_000
        let whPerKm = netWh / distanceKm
        guard distanceKm.isFinite, distanceKm > 0,
              whPerKm.isFinite, whPerKm > 0 else {
            return unavailable(.noValidIntervals)
        }
        // 主服务使用安卓固定曲线积分结果；旧调用保留固定系数接口。
        let remainingWh = remainingEnergyWh ?? (remainingAh * effectiveWhPerAh)
        guard remainingWh.isFinite, remainingWh >= 0,
              remainingAh != 0 || remainingWh == 0 else { return unavailable(.capacityInvalid) }
        let rangeKm = remainingWh / whPerKm
        guard rangeKm.isFinite, rangeKm >= 0,
              remainingAh == 0 || rangeKm > 0 else {
            return unavailable(.noValidIntervals)
        }
        return RangePrediction(predictedRangeKm: rangeKm, reason: .valid)
    }

    private func unavailable(_ status: RangePredictionStatus) -> RangePrediction {
        RangePrediction(predictedRangeKm: nil, reason: status)
    }
}

/// 过渡别名：保留早期接入代码，但新 UI 应使用名称更明确的 `BasicRangePredictor`。
public typealias RangePredictor = BasicRangePredictor
public typealias RangeStatus = RangePredictionStatus
public typealias RangePredictionReason = RangePredictionStatus
