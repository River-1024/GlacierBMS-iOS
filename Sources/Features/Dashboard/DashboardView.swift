import ANTuRideDomain
import SwiftUI

/// 首页驾驶仪表盘。阶段 2 绑定 BMS 实时数据与 GPS 速度/行程控制；
/// 综合续航属阶段 3，以占位呈现，不伪造数值。
struct DashboardView: View {
    var goToDeviceSelection: () -> Void = {}

    @EnvironmentObject private var bms: BmsBluetoothService
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var tripSession: TripSessionService

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snapshot = bms.latestSnapshot
                let freshness = BmsFreshnessEvaluator().evaluate(snapshot: snapshot, now: context.date)
                ScrollView {
                    VStack(spacing: 16) {
                        ConnectionStatusCard(
                            state: bms.state,
                            freshness: freshness,
                            connectedName: bms.connectedDeviceName,
                            goToDeviceSelection: goToDeviceSelection
                        )
                        SpeedCard(fix: location.lastFix)
                        TripControlCard(
                            state: tripSession.state,
                            distanceMeters: tripSession.liveDistanceMeters,
                            energyWh: tripSession.liveEnergyWh,
                            lastError: tripSession.lastError,
                            onStart: { tripSession.startTrip() },
                            onStop: { tripSession.stopTrip() }
                        )
                        HStack(spacing: 12) {
                            MetricCard(title: "综合续航", value: "--", unit: "km", caption: "阶段 3 接入")
                            MetricCard(
                                title: "SOC",
                                value: displayValue(freshness) { BmsFormatters.percent($0.soc) },
                                unit: "%",
                                isStale: freshness.level == .stale
                            )
                        }
                        HStack(spacing: 12) {
                            MetricCard(
                                title: "剩余电量",
                                value: displayValue(freshness) { BmsFormatters.voltage($0.remainingAh) },
                                unit: "Ah",
                                isStale: freshness.level == .stale
                            )
                            MetricCard(
                                title: "功率",
                                value: displayValue(freshness) { snapshot in
                                    snapshot.power.map(BmsFormatters.kilowatts) ?? "--"
                                },
                                unit: "kW",
                                isStale: freshness.level == .stale
                            )
                        }
                        HStack(spacing: 12) {
                            MetricCard(
                                title: "电流",
                                value: displayValue(freshness) { BmsFormatters.current($0.current) },
                                unit: "A",
                                isStale: freshness.level == .stale
                            )
                            MetricCard(
                                title: "总电压",
                                value: displayValue(freshness) { BmsFormatters.voltage($0.totalVoltage) },
                                unit: "V",
                                isStale: freshness.level == .stale
                            )
                        }
                        MetricCard(
                            title: "总容量 / SOH",
                            value: displayValue(freshness) { snapshot in
                                snapshot.capacityAh > 0 ? BmsFormatters.voltage(snapshot.capacityAh) : "--"
                            },
                            unit: "Ah",
                            caption: displayValue(freshness) { snapshot in
                                snapshot.soh.map { "SOH \($0)%" } ?? "SOH --"
                            },
                            isStale: freshness.level == .stale
                        )
                        StatusChipsCard(snapshot: freshness.level == .noData ? nil : snapshot, isStale: freshness.level == .stale)
                        CurrentChartCard(history: bms.snapshotHistory)
                    }
                    .padding()
                }
                .navigationTitle("安途")
            }
        }
    }

    private func displayValue(_ freshness: BmsDataFreshness, transform: (BmsSnapshot) -> String) -> String {
        guard let snapshot = bms.latestSnapshot, freshness.level != .noData else { return "--" }
        return transform(snapshot)
    }
}

private struct ConnectionStatusCard: View {
    let state: BmsBluetoothService.State
    let freshness: BmsDataFreshness
    let connectedName: String?
    let goToDeviceSelection: () -> Void

    var body: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.subheadline.weight(.medium))
                Text(freshnessText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .ready {
                Text(connectedName ?? "ANT BMS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("选择设备", action: goToDeviceSelection)
                    .adaptiveGlassProminentButton()
                    .controlSize(.small)
            }
        }
        .padding()
        .glassCard(cornerRadius: 16)
    }

    private var statusColor: Color {
        switch state {
        case .ready: return freshness.level == .stale ? AppTheme.warning : AppTheme.success
        case .scanning, .connecting, .discovering, .reconnecting: return AppTheme.accent
        case .poweredOff: return .secondary
        case .idle, .disconnected: return AppTheme.warning
        }
    }

    private var statusText: String {
        switch state {
        case .idle: return "尚未连接 BMS"
        case .poweredOff: return "蓝牙未开启"
        case .scanning: return "正在扫描设备…"
        case .connecting: return "正在连接…"
        case .discovering: return "正在发现服务…"
        case .ready: return "已连接"
        case .reconnecting: return "连接中断，正在重连…"
        case .disconnected: return "尚未连接 BMS"
        }
    }

    private var freshnessText: String {
        switch freshness.level {
        case .noData: return "等待 BMS 数据"
        case .fresh: return "数据实时"
        case .stale: return "数据已过期 \(Int(freshness.ageSeconds ?? 0))s"
        }
    }
}

private struct SpeedCard: View {
    /// 最近一次 GPS 定位；nil 表示尚未定位。
    let fix: GpsFix?

    var body: some View {
        VStack(spacing: 4) {
            Text(speedText)
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("km/h").foregroundStyle(AppTheme.accent)
            Text(captionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .glassCard()
    }

    private var speedKmh: Double? {
        guard let fix, fix.isSpeedValid else { return nil }
        return fix.speed * 3.6
    }

    private var speedText: String {
        guard let speed = speedKmh else { return "--" }
        return String(format: "%.0f", speed)
    }

    private var captionText: String {
        guard let fix else { return "等待 GPS 定位" }
        guard fix.isSpeedValid else { return "定位有效，速度待更新" }
        if fix.horizontalAccuracy >= 0 {
            return String(format: "GPS 精度 ±%.0fm", fix.horizontalAccuracy)
        }
        return "GPS 实时"
    }
}

/// 行程控制卡：开始/结束行程，实时里程与净能耗。
/// 空闲态显示占位说明，不伪造数值。
private struct TripControlCard: View {
    let state: TripState
    let distanceMeters: Double
    let energyWh: Double
    let lastError: String?
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(statusText, systemImage: statusIcon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSuspended ? AppTheme.warning : AppTheme.accent)
                Spacer()
                if state == .idle {
                    Button("开始行程", action: onStart)
                        .adaptiveGlassProminentButton()
                        .controlSize(.small)
                } else {
                    Button("结束行程", action: onStop)
                        .adaptiveGlassProminentButton()
                        .controlSize(.small)
                }
            }
            if state != .idle {
                HStack(spacing: 12) {
                    stat(title: "里程", value: String(format: "%.2f", distanceMeters / 1000), unit: "km")
                    stat(title: "净能耗", value: String(format: "%.1f", energyWh), unit: "Wh")
                }
            } else {
                Text("开始行程后记录 GPS 速度、里程与 BMS 能耗；锁屏自动暂停并标记区间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .padding()
        .glassCard(cornerRadius: 16)
    }

    private var isSuspended: Bool { state == .suspended }

    private var statusText: String {
        switch state {
        case .idle: return "行程"
        case .recording: return "行程记录中"
        case .suspended: return "已暂停（锁屏）"
        case .finished: return "行程"
        }
    }

    private var statusIcon: String {
        switch state {
        case .suspended: return "lock"
        case .recording: return "record.circle"
        default: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }

    private func stat(title: String, value: String, unit: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(AppTheme.accent)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    var caption: String? = nil
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? Color.secondary : Color.primary)
                Text(unit).font(.caption).foregroundStyle(AppTheme.accent)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard(cornerRadius: 16)
    }
}

private struct StatusChipsCard: View {
    let snapshot: BmsSnapshot?
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            chip(title: snapshot?.statusText ?? "--", color: snapshot == nil ? .secondary : AppTheme.accent)
            chip(
                title: mosText("充电", snapshot?.chargeMOSOn),
                color: mosColor(snapshot?.chargeMOSOn)
            )
            chip(
                title: mosText("放电", snapshot?.dischargeMOSOn),
                color: mosColor(snapshot?.dischargeMOSOn)
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .glassCard(cornerRadius: 16)
        .opacity(isStale ? 0.7 : 1)
    }

    private func mosText(_ prefix: String, _ on: Bool?) -> String {
        guard let on else { return "\(prefix) MOS --" }
        return "\(prefix) MOS \(on ? "开" : "关")"
    }

    private func mosColor(_ on: Bool?) -> Color {
        guard let on else { return .secondary }
        return on ? AppTheme.success : Color.secondary
    }

    private func chip(title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 电流滚动曲线：直接使用 Canvas 绘制，不引入图表依赖。
private struct CurrentChartCard: View {
    let history: [BmsSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("电流曲线").font(.headline)
                Spacer()
                Text("最近 \(history.count) 次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Group {
                if history.count >= 2 {
                    CurrentChart(samples: history.map(\.current))
                } else {
                    Text("等待实时数据…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard()
    }
}

private struct CurrentChart: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2,
                  let minValue = samples.min(),
                  let maxValue = samples.max() else { return }
            let range = max(maxValue - minValue, 0.5)
            let inset = size.height * 0.1
            let drawableHeight = size.height - inset * 2

            var path = Path()
            for (index, value) in samples.enumerated() {
                let ratio = CGFloat((value - minValue) / range)
                let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = inset + drawableHeight * (1 - ratio)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(AppTheme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            let maxLabel = Text(String(format: "%.1f A", maxValue)).font(.caption2)
            context.draw(context.resolve(maxLabel), at: CGPoint(x: size.width - 24, y: inset + 6))
        }
        .frame(height: 140)
    }
}
