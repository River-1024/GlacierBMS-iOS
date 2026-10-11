import Foundation

/// 普通驾驶偏好，仅供调用方读取；不连接设备、不写硬件、不保存外设 UUID。
/// 默认值/限制来自 Android DashboardModels.kt 的 DashboardSettings/normalized()，
/// DashboardPrefs 的两个启动自动连接开关，以及 DashboardScreens.kt 的 SettingsForm。
public struct DrivingSettings: Codable, Equatable, Sendable {
    public enum ThemeMode: String, Codable, CaseIterable, Sendable {
        case system = "SYSTEM"
        case light = "LIGHT"
        case dark = "DARK"
    }

    public enum PowerDisplayMode: String, Codable, CaseIterable, Sendable {
        case powerBar = "POWER_BAR"
        case curve = "CURVE"
    }

    public static let rangeWindowMinutesBounds = 3...60
    public static let rangeRefreshSecondsBounds = 10...60
    /// Android 的 dashboard_bluetooth_refresh_interval_ms 是 BMS 查询周期，
    /// 不是控制器独立的 controller_sampling_interval_ms。
    public static let bluetoothRefreshIntervalMsBounds = 100...60_000
    public static let valueScaleBounds = 0.5...2.0
    public static let temperatureBounds = -50.0...150.0
    public static let speedBaseBounds = 1.0...300.0

    public var rangeWindowMinutes = 15
    public var rangeRefreshSeconds = 10
    public var valueScale = 1.0
    public var showTextDescriptions = false
    public var defaultPowerDisplayMode: PowerDisplayMode = .curve
    public var appThemeMode: ThemeMode = .system
    public var bluetoothRefreshIntervalMs = 1_000
    /// 与 Android 一样允许自由文本；“自动”为默认，数字表示从 1 开始的探头序号。
    /// 实际探头选择/越界回退须由消费端对有效遥测实现，不能在设置页假定探头数量。
    public var temperatureSource = "自动"
    public var dischargeBaseW = 6_000.0
    public var chargeBaseW = 2_500.0
    public var powerYellowStart = 0.55
    public var powerRedStart = 0.90
    public var socRedUpperPercent = 10.0
    public var socYellowUpperPercent = 20.0
    public var diffGreenUpperMv = 20.0
    public var diffYellowUpperMv = 50.0
    public var tempGreenUpperC = 39.0
    public var tempYellowUpperC = 45.0
    public var powerHeaderSpeedBaseKmh = 80.0
    public var powerHeaderSpeedMidKmh = 30.0
    public var powerHeaderSpeedHighKmh = 60.0
    /// 只表示 App 启动时自动连接意愿；不影响手动连接/断开，也不保证连接成功。
    public var bmsAutoConnectEnabled = true
    public var controllerAutoConnectEnabled = true

    public init() {}

    public static let defaults = DrivingSettings()

    public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
        public let messages: [String]
        public var errorDescription: String? { messages.joined(separator: "\n") }
    }

    public var isValid: Bool { validationErrors.isEmpty }

    /// 对编辑输入严格检查，不静默修正用户输入；所有 Double 必须有限。
    /// 阈值允许相等，与 Android normalized() 保持一致。
    public var validationErrors: [String] {
        var errors: [String] = []
        if !Self.rangeWindowMinutesBounds.contains(rangeWindowMinutes) {
            errors.append("续航窗口必须为 3–60 分钟的整数。")
        }
        if !Self.rangeRefreshSecondsBounds.contains(rangeRefreshSeconds) {
            errors.append("续航刷新必须为 10–60 秒的整数。")
        }
        if !Self.bluetoothRefreshIntervalMsBounds.contains(bluetoothRefreshIntervalMs) {
            errors.append("BMS 查询周期必须为 100–60000 ms 的整数。")
        }
        func check(_ value: Double, _ allowed: ClosedRange<Double>, _ message: String) {
            if !value.isFinite || !allowed.contains(value) { errors.append(message) }
        }
        func minimum(_ value: Double, _ lower: Double, _ message: String) {
            if !value.isFinite || value < lower { errors.append(message) }
        }
        check(valueScale, Self.valueScaleBounds, "数值字号比例必须为 0.5–2.0。")
        minimum(dischargeBaseW, 1, "放电功率条基数必须为不小于 1 W 的有限数值。")
        minimum(chargeBaseW, 1, "充电功率条基数必须为不小于 1 W 的有限数值。")
        check(powerYellowStart, 0...1, "功率黄色起点必须为 0–1。")
        check(powerRedStart, 0...1, "功率红色起点必须为 0–1。")
        check(socRedUpperPercent, 0...100, "SOC 红色上限必须为 0–100%。")
        check(socYellowUpperPercent, 0...100, "SOC 黄色上限必须为 0–100%。")
        minimum(diffGreenUpperMv, 0, "压差绿色上限必须为非负有限数值（mV）。")
        minimum(diffYellowUpperMv, 0, "压差黄色上限必须为非负有限数值（mV）。")
        check(tempGreenUpperC, Self.temperatureBounds, "温度绿色上限必须为 -50–150 °C。")
        check(tempYellowUpperC, Self.temperatureBounds, "温度黄色上限必须为 -50–150 °C。")
        check(powerHeaderSpeedBaseKmh, Self.speedBaseBounds, "标题速度满格必须为 1–300 km/h。")
        minimum(powerHeaderSpeedMidKmh, 0, "标题中速阈值必须为非负有限数值。")
        minimum(powerHeaderSpeedHighKmh, 0, "标题高速阈值必须为非负有限数值。")
        if powerYellowStart > powerRedStart {
            errors.append("功率黄色起点不能大于红色起点。")
        }
        if socRedUpperPercent > socYellowUpperPercent {
            errors.append("SOC 红色上限不能大于黄色上限。")
        }
        if diffGreenUpperMv > diffYellowUpperMv {
            errors.append("压差绿色上限不能大于黄色上限。")
        }
        if tempGreenUpperC > tempYellowUpperC {
            errors.append("温度绿色上限不能大于黄色上限。")
        }
        if powerHeaderSpeedMidKmh > powerHeaderSpeedHighKmh ||
            powerHeaderSpeedHighKmh > powerHeaderSpeedBaseKmh {
            errors.append("标题速度阈值必须满足：中速 ≤ 高速 ≤ 满格。")
        }
        return errors
    }

    public func validate() throws {
        let errors = validationErrors
        if !errors.isEmpty { throw ValidationError(messages: errors) }
    }

    public mutating func restoreDefaults() { self = Self.defaults }

    /// 用于读取旧/异常存储，有限值按 Android 限制夹取；NaN/无穷回退对应默认。
    /// 不把“已规范化的偏好”作为算法、主题或蓝牙已生效的证明。
    public func normalized() -> DrivingSettings {
        var safe = self
        let defaults = Self.defaults
        func clamp(_ value: Int, _ bounds: ClosedRange<Int>) -> Int {
            min(max(value, bounds.lowerBound), bounds.upperBound)
        }
        func bound(_ value: Double, _ bounds: ClosedRange<Double>, _ fallback: Double) -> Double {
            let finite = value.isFinite ? value : fallback
            return min(max(finite, bounds.lowerBound), bounds.upperBound)
        }
        func floor(_ value: Double, _ lower: Double, _ fallback: Double) -> Double {
            max(value.isFinite ? value : fallback, lower)
        }
        safe.rangeWindowMinutes = clamp(rangeWindowMinutes, Self.rangeWindowMinutesBounds)
        safe.rangeRefreshSeconds = clamp(rangeRefreshSeconds, Self.rangeRefreshSecondsBounds)
        safe.bluetoothRefreshIntervalMs = clamp(bluetoothRefreshIntervalMs, Self.bluetoothRefreshIntervalMsBounds)
        safe.valueScale = bound(valueScale, Self.valueScaleBounds, defaults.valueScale)
        safe.dischargeBaseW = floor(dischargeBaseW, 1, defaults.dischargeBaseW)
        safe.chargeBaseW = floor(chargeBaseW, 1, defaults.chargeBaseW)
        safe.powerYellowStart = bound(powerYellowStart, 0...1, defaults.powerYellowStart)
        safe.powerRedStart = bound(powerRedStart, safe.powerYellowStart...1, defaults.powerRedStart)
        safe.socRedUpperPercent = bound(socRedUpperPercent, 0...100, defaults.socRedUpperPercent)
        safe.socYellowUpperPercent = bound(socYellowUpperPercent, safe.socRedUpperPercent...100, defaults.socYellowUpperPercent)
        safe.diffGreenUpperMv = floor(diffGreenUpperMv, 0, defaults.diffGreenUpperMv)
        safe.diffYellowUpperMv = floor(diffYellowUpperMv, safe.diffGreenUpperMv, defaults.diffYellowUpperMv)
        safe.tempGreenUpperC = bound(tempGreenUpperC, Self.temperatureBounds, defaults.tempGreenUpperC)
        safe.tempYellowUpperC = bound(tempYellowUpperC, safe.tempGreenUpperC...150, defaults.tempYellowUpperC)
        // Android 对非法满格速度回退 80，而不是夹取到 1 或 300。
        safe.powerHeaderSpeedBaseKmh = powerHeaderSpeedBaseKmh.isFinite &&
            Self.speedBaseBounds.contains(powerHeaderSpeedBaseKmh) ? powerHeaderSpeedBaseKmh : defaults.powerHeaderSpeedBaseKmh
        safe.powerHeaderSpeedMidKmh = bound(powerHeaderSpeedMidKmh, 0...safe.powerHeaderSpeedBaseKmh, defaults.powerHeaderSpeedMidKmh)
        safe.powerHeaderSpeedHighKmh = bound(powerHeaderSpeedHighKmh, safe.powerHeaderSpeedMidKmh...safe.powerHeaderSpeedBaseKmh, defaults.powerHeaderSpeedHighKmh)
        let source = temperatureSource.trimmingCharacters(in: .whitespacesAndNewlines)
        safe.temperatureSource = source.isEmpty ? defaults.temperatureSource : source
        return safe
    }
}
