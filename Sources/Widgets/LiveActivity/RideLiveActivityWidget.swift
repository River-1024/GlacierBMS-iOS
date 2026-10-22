import ActivityKit
import SwiftUI
import WidgetKit

/// 骑行实时活动的四态视图：紧凑、最小、展开、锁屏卡片。
///
/// 布局约束（灵动岛区域固定，Dynamic Type 不可用）：
/// - 紧凑态左右各约 60pt，只放一个图标或一个数字，单位一律省略。
/// - 展开态 leading/trailing 各放一个主数值，bottom 放三个次级指标。
/// - 空间受限场景用固定字号是有意例外：语义字号在最大辅助字号下会溢出被裁切。
/// - 数值缺失一律显示 `--`，绝不显示 0；数据过期必须显示文案，不只靠颜色。
struct RideLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RideActivityFormat.speed(context.state.speedKmh))
                            .font(.system(size: 26, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("km/h")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(RideActivityFormat.soc(context.state.socPercent))
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text(context.state.source.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 14) {
                        Label(RideActivityFormat.power(context.state.powerWatts), systemImage: "bolt")
                        Label(RideActivityFormat.distance(context.state.distanceMeters), systemImage: "location")
                        Label {
                            Text(context.attributes.startedAt, style: .timer)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "clock")
                        }
                        Spacer(minLength: 0)
                        if let note = context.state.freshness.note {
                            Text(note).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName: RideActivityFormat.batterySymbol(context.state.socPercent))
                    .foregroundStyle(RideActivityFormat.socTint(context.state.socPercent))
            } compactTrailing: {
                Text(RideActivityFormat.soc(context.state.socPercent))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Text(context.attributes.showsSpeed
                     ? RideActivityFormat.speed(context.state.speedKmh)
                     : RideActivityFormat.soc(context.state.socPercent))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .keylineTint(RideActivityFormat.socTint(context.state.socPercent))
        }
    }
}

/// 锁屏卡片：所有机型可用（含非灵动岛 iPhone）。
struct RideLockScreenView: View {
    let context: ActivityViewContext<RideActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("安途 · 骑行中")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                metric(RideActivityFormat.speed(context.state.speedKmh), unit: "km/h")
                metric(RideActivityFormat.soc(context.state.socPercent), unit: "SOC")
                metric(RideActivityFormat.power(context.state.powerWatts), unit: context.state.isCharging ? "充电" : "功率")
                metric(RideActivityFormat.distance(context.state.distanceMeters), unit: "里程")
            }
            if let note = context.state.freshness.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private func metric(_ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// extension 内的最小格式化集合。不复用 App 的 Formatters：
/// 实时活动不需要上千分位/长单位，且应避免把 Domain 依赖带进 extension。
enum RideActivityFormat {
    static func speed(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    static func soc(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    static func power(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let kw = value / 1000
        if abs(kw) >= 0.1 { return String(format: "%.1f kW", kw) }
        return String(format: "%.0f W", value)
    }

    static func distance(_ meters: Double) -> String {
        guard meters.isFinite, meters > 0 else { return "--" }
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return String(format: "%.0f m", meters)
    }

    static func batterySymbol(_ soc: Double?) -> String {
        guard let soc, soc.isFinite else { return "battery.0percent" }
        switch soc {
        case ..<10: return "battery.0percent"
        case ..<25: return "battery.25percent"
        case ..<50: return "battery.50percent"
        case ..<75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// 与 `DrivingSettings.socRedUpperPercent = 10` / `socYellowUpperPercent = 20` 保持一致，
    /// 避免锁屏与 App 内出现两套阈值。
    static func socTint(_ soc: Double?) -> Color {
        guard let soc, soc.isFinite else { return .secondary }
        if soc <= 10 { return .red }
        if soc <= 20 { return .orange }
        return .green
    }
}
