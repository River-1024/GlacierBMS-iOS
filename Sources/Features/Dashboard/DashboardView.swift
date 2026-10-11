import ANTuRideDomain
import SwiftUI

/// 首页驾驶仪表盘。连接与行程控制固定显示，其余实时卡片使用已保存布局。
@MainActor
struct DashboardView: View {
    var goToDeviceSelection: () -> Void = {}

    @EnvironmentObject private var bms: BmsBluetoothService
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var tripSession: TripSessionService
    @EnvironmentObject private var rangeService: RangeService
    @EnvironmentObject private var controller: ControllerBluetoothService
    @EnvironmentObject private var driving: DrivingSettingsStore
    // 与设置编辑器共用同一偏好键；保存后即使 Tab 未重建也会刷新。
    @AppStorage(HomeParameterPrefs.key) private var storedLayout = ""

    private var homeConfig: HomeParameterConfig {
        HomeParameterPrefs.decode(storedLayout) ?? .androidDefault
    }

    private var rangeDisplay: String {
        guard rangeService.status == .valid,
              let kilometers = rangeService.prediction?.predictedRangeKm,
              kilometers.isFinite, kilometers >= 0 else { return "--" }
        return String(format: "%.1f", kilometers)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let freshness = BmsFreshnessEvaluator().evaluate(snapshot: bms.latestSnapshot, now: context.date)
                    // 窄屏保持单列；横屏/宽屏双列，顺序始终从左到右、从上到下。
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: geometry.size.width >= 600 ? 2 : 1)
                    ScrollView {
                        VStack(spacing: 16) {
                            ConnectionStatusCard(
                                state: bms.state,
                                freshness: freshness,
                                connectedName: bms.connectedDeviceName,
                                goToDeviceSelection: goToDeviceSelection
                            )
                            TripControlCard(
                                state: tripSession.state,
                                distanceMeters: tripSession.liveDistanceMeters,
                                energyWh: tripSession.liveEnergyWh,
                                lastError: tripSession.lastError,
                                onStart: { tripSession.startTrip() },
                                onStop: { tripSession.stopTrip() }
                            )
                            if homeConfig.usesSlotLayout {
                                slotDashboard(freshness: freshness, size: geometry.size)
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(homeConfig.visibleCardIDs) { id in
                                        parameterCard(id, freshness: freshness)
                                            .accessibilityIdentifier("dashboard.card.\(id.rawValue)")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .navigationTitle("安途")
                }
            }
        }
    }

    /// 兼容已保存的旧版十卡片布局，不因切换到槽位布局而丢失用户偏好。
    @ViewBuilder
    private func parameterCard(_ id: HomeParameterCardID, freshness: BmsDataFreshness) -> some View {
        switch id {
        case .currentChart: powerGraphic
        case .status:
            StatusChipsCard(snapshot: freshness.level == .fresh ? bms.latestSnapshot : nil, isStale: freshness.level == .stale)
        case .capacityAndHealth:
            VStack { slotCard(.init(slotId: id.rawValue, metricId: "bms_capacity"), freshness: freshness)
                slotCard(.init(slotId: "soh", metricId: "bms_soh"), freshness: freshness) }
        default:
            slotCard(.init(slotId: id.rawValue, metricId: legacyMetricID(id)), freshness: freshness, fontSize: 32)
        }
    }

    private func legacyMetricID(_ id: HomeParameterCardID) -> String {
        switch id {
        case .speed: return "app_gps_speed"
        case .range: return "app_range"
        case .stateOfCharge: return "bms_soc"
        case .remainingCapacity: return "bms_remaining"
        case .power: return "bms_power"
        case .current: return "bms_current"
        case .voltage: return "bms_voltage"
        case .capacityAndHealth: return "bms_capacity"
        case .status: return "bms_status"
        case .currentChart: return "bms_current"
        }
    }

    @ViewBuilder
    private var powerGraphic: some View {
        if driving.settings.defaultPowerDisplayMode == .curve {
            PowerChartCard(history: bms.snapshotHistory)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("实时功率").font(.headline)
                if let snapshot = bms.latestSnapshot, bms.state == .ready,
                   BmsFreshnessEvaluator().evaluate(snapshot: snapshot, now: Date()).level == .fresh,
                   let power = snapshot.power, power.isFinite {
                    let base = power >= 0 ? driving.settings.dischargeBaseW : driving.settings.chargeBaseW
                    ProgressView(value: min(1, abs(power) / base))
                        .tint(metricColor("bms_power", snapshot: snapshot))
                    Text(String(format: "%.0f W / %.0f W", power, base)).monospacedDigit()
                } else { Text("--").foregroundStyle(.secondary) }
            }.padding().glassCard()
        }
    }

    @ViewBuilder
    private func slotDashboard(freshness: BmsDataFreshness, size: CGSize) -> some View {
        let portrait = HomeParameterLayout.isPortrait(width: Double(size.width), height: Double(size.height))
        if portrait {
            topSlotCards(freshness: freshness, portrait: true)
            powerGraphic
                .frame(minHeight: 190)
        } else {
            HStack(alignment: .top, spacing: 10) {
                topSlotCards(freshness: freshness, portrait: false)
                    .frame(width: 290)
                powerGraphic
                    .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        bottomSlots(in: .vehicle, freshness: freshness)
        bottomSlots(in: .controller, freshness: freshness)
    }

    private func topSlotCards(freshness: BmsDataFreshness, portrait: Bool) -> some View {
        VStack(spacing: portrait ? 8 : 6) {
            ForEach(HomeParameterSlotDefinition.heroIDs, id: \.self) { slotId in
                if let metricId = homeConfig.metricId(for: slotId) {
                    slotCard(HomeParameterAssignment(slotId: slotId, metricId: metricId), freshness: freshness,
                             fontSize: slotId == "top_speed" ? (portrait ? 84 : 60) : (portrait ? 32 : 26))
                        .frame(minHeight: slotId == "top_speed" ? (portrait ? 148 : 96) : (portrait ? 82 : 60))
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(HomeParameterSlotDefinition.gridIDs, id: \.self) { slotId in
                    if let metricId = homeConfig.metricId(for: slotId) {
                        slotCard(HomeParameterAssignment(slotId: slotId, metricId: metricId), freshness: freshness,
                                 fontSize: portrait ? 28 : 22)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bottomSlots(in region: HomeParameterRegion, freshness: BmsDataFreshness) -> some View {
        let rows = HomeParameterLayout.rows(homeConfig.assignments(in: region), in: region)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(region.title).font(.headline)
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    GeometryReader { geometry in
                        let column = max(0, (geometry.size.width - 16) / 3)
                        HStack(spacing: 8) {
                            ForEach(row) { assignment in
                                let span = HomeParameterLayout.span(assignment, in: region)
                                slotCard(assignment, freshness: freshness)
                                    .frame(width: column * CGFloat(span) + CGFloat(span - 1) * 8)
                            }
                        }
                    }.frame(height: 118)

                }
            }
        }
    }

    private func slotCard(_ assignment: HomeParameterAssignment, freshness: BmsDataFreshness,
                          fontSize: CGFloat = 14) -> some View {
        let snapshot = bms.state == .ready && freshness.level == .fresh ? bms.latestSnapshot : nil
        let readout = HomeParameterReadout.read(
            metricId: assignment.metricId, snapshot: snapshot,
            gpsSpeedKmh: location.lastFix.flatMap { fix in
                let age = Date().timeIntervalSince(fix.timestamp)
                return location.isUpdating && age >= 0 && age <= 10 && fix.isSpeedValid ? fix.speed * 3.6 : nil
            },
            rangeKm: rangeService.status == .valid ? rangeService.prediction?.predictedRangeKm : nil,
            consumptionWhPerKm: rangeService.status == .valid ? rangeService.effectiveWhPerKm : nil,
            controller: freshControllerTelemetry, settings: driving.settings,
            averageSpeedKmh: rangeService.averageSpeedKmh, referenceKmPerAh: rangeService.referenceKmPerAh,
            bmsRSSI: bms.rssiReceivedAt.flatMap { date in
                let age = Date().timeIntervalSince(date)
                return bms.state == .ready && age >= 0 && age <= 10 ? bms.rssi : nil
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(driving.settings.showTextDescriptions ? readout.title : readout.title.components(separatedBy: " · ").last ?? readout.title).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Text(readout.value).font(.system(size: fontSize * driving.settings.valueScale, weight: .semibold, design: .rounded))
                .foregroundStyle(metricColor(assignment.metricId, snapshot: snapshot))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.3)
            if !readout.unit.isEmpty { Text(readout.unit).font(.caption2).foregroundStyle(AppTheme.accent) }
            if assignment.metricId == "app_gps_speed", let fix = location.lastFix, let speed = fix.speedKmhForDisplay,
               location.isUpdating, Date().timeIntervalSince(fix.timestamp) >= 0,
               Date().timeIntervalSince(fix.timestamp) <= 10 {
                ProgressView(value: min(1, max(0, speed) / driving.settings.powerHeaderSpeedBaseKmh))
                    .tint(metricColor(assignment.metricId, snapshot: snapshot))
            }
            if driving.settings.showTextDescriptions && assignment.metricId == "app_range" {
                Text(rangeService.reasonText).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassCard(cornerRadius: 8)
        .accessibilityIdentifier("dashboard.slot.\(assignment.slotId)")
    }
    private var freshControllerTelemetry: MotorControllerTelemetry? {
        guard controller.state == .ready, let snapshot = controller.latestSnapshot else { return nil }
        let age = Date().timeIntervalSince(snapshot.receivedAt)
        return age >= 0 && age <= ControllerBluetoothService.responseTimeout ? snapshot.telemetry : nil
    }

    private func metricColor(_ id: String, snapshot: BmsSnapshot?) -> Color {
        switch HomeMetricPresentation.tone(id, snapshot: snapshot, speedKmh: location.lastFix?.speedKmhForDisplay,
                                          settings: driving.settings) {
        case .neutral: return .primary
        case .green: return AppTheme.success
        case .yellow: return AppTheme.warning
        case .red: return AppTheme.danger
        }
    }

}

/// 取数只按指标来源，不按槽位原位置；控制器值仅从独立实时链路读取。
/// 纯取数函数可由 AppTests 验证，不触发蓝牙、定位或服务初始化。
struct HomeParameterReadout: Equatable {
    let title: String
    let value: String
    let unit: String

    static func read(metricId: String, snapshot: BmsSnapshot? = nil,
                     gpsSpeedKmh: Double? = nil, rangeKm: Double? = nil,
                     consumptionWhPerKm: Double? = nil,
                     controller: MotorControllerTelemetry? = nil, settings: DrivingSettings = .defaults,
                     averageSpeedKmh: Double? = nil, referenceKmPerAh: Double? = nil,
                     bmsRSSI: Int? = nil) -> Self {
        let definition = HomeParameterMetricDefinition.definition(for: metricId)
        var value = "--"
        var unit = definition?.unit ?? ""
        func number(_ value: Double?, _ decimals: Int = 1) -> String {
            guard let value, value.isFinite else { return "--" }
            return String(format: "%.*f", decimals, value)
        }
        switch metricId {
        case "app_gps_speed": value = number(gpsSpeedKmh.map { max(0, $0) })
        case "app_range": value = number(rangeKm.flatMap { $0 >= 0 ? $0 : nil })
        case "app_consumption": value = number(consumptionWhPerKm.flatMap { $0 > 0 ? $0 : nil }, 0)
        case "app_average_speed": value = number(averageSpeedKmh)
        case "app_reference_consumption": value = number(referenceKmPerAh)
        case "bms_rssi": value = bmsRSSI.map(String.init) ?? "--"
        case "bms_remaining": value = number(snapshot?.remainingAh)
        case "bms_soc": value = number(snapshot?.soc, 0)
        case "bms_power":
            if let power = snapshot?.power, power.isFinite {
                unit = abs(power) >= 1_000 ? "kW" : "W"
                value = number(unit == "kW" ? power / 1_000 : power, unit == "kW" ? 2 : 0)
            }
        case "bms_current": value = number(snapshot?.current)
        case "bms_voltage": value = number(snapshot?.totalVoltage)
        case "bms_diff": value = snapshot?.voltageDiffMillivolts.map { String($0) } ?? "--"
        case "bms_temperature": value = HomeMetricPresentation.temperature(snapshot, settings: settings).map { String($0) } ?? "--"
        case "bms_mos_temperature": value = snapshot.map { String($0.mosTemperature) } ?? "--"
        case "bms_cell_count": value = snapshot.map { String($0.cellVoltagesMillivolts.count) } ?? "--"
        case "bms_status": value = snapshot?.statusText ?? "--"
        case "bms_mos_status":
            if let snapshot {
                if snapshot.chargeMOSOn == nil && snapshot.dischargeMOSOn == nil { value = "未知" }
                else {
                    value = "充电\(snapshot.chargeMOSOn == true ? "开" : "关") · 放电\(snapshot.dischargeMOSOn == true ? "开" : "关")"
                }
            }
        case "bms_soh": value = snapshot?.soh.map { String($0) } ?? "--"
        case "bms_runtime":
            if let seconds = snapshot?.runtimeSeconds {
                let days = seconds / 86_400
                let hours = seconds % 86_400 / 3_600
                value = days > 0 ? "\(days)天 \(hours)小时" : "\(hours)小时"
            }
        case "bms_capacity": value = number(snapshot?.capacityAh, 2)
        case "bms_balancer_temperature": value = snapshot.map { String($0.balancerTemperature) } ?? "--"
        case "controller_voltage": value = number(controller?.controllerVoltageV)
        case "controller_bus_current": value = number(controller?.busCurrentA)
        case "controller_rpm": value = controller.map { String($0.rpm) } ?? "--"
        case "controller_temperature": value = controller.map { String($0.controllerTemperatureC) } ?? "--"
        case "controller_motor_temperature": value = controller.map { String($0.motorTemperatureC) } ?? "--"
        case "controller_phase_current": value = number(controller?.phasePeakCurrentA)
        case "controller_run_state": value = controller?.runStateText ?? "--"
        case "controller_fault": value = controller?.faultSummary ?? "--"
        case "controller_throttle_voltage": value = number(controller?.throttleVoltageV)
        case "controller_gear": value = controller.map { String($0.gear) } ?? "--"
        case "controller_state_bits": value = controller.map { String($0.controllerStateBits) } ?? "--"
        case "controller_port_bits": value = controller.map { String($0.portStatusBits) } ?? "--"
        case "controller_given_iq": value = number(controller?.givenIqA)
        case "controller_feedback_iq": value = number(controller?.feedbackIqA)
        case "controller_given_id": value = number(controller?.givenIdA)
        case "controller_field_weakening": value = number(controller?.fieldWeakeningA)
        case "controller_history_fault_bits": value = controller.map { String($0.historyFaultBits) } ?? "--"
        case "controller_linear_brake_voltage": value = number(controller?.linearBrakeVoltageV)
        default: break
        }
        return Self(title: definition?.title ?? metricId, value: value, unit: value == "--" ? "" : unit)
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


/// Historical measured power, never an amperage curve relabeled as watts.
private struct PowerChartCard: View {
    let history: [BmsSnapshot]
    var body: some View {
        let values = history.compactMap { snapshot -> Double? in
            guard let value = snapshot.power, value.isFinite else { return nil }
            return value
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("历史功率曲线 · W").font(.headline)
            if values.count >= 2, let first = history.first, let last = history.last,
               last.receivedAt > first.receivedAt {
                Canvas { context, size in
                    let minimum = min(values.min() ?? 0, 0)
                    let maximum = max(values.max() ?? 0, 1)
                    let span = max(1, maximum - minimum)
                    let duration = last.receivedAt.timeIntervalSince(first.receivedAt)
                    var path = Path()
                    var previous: Date?
                    for sample in history {
                        guard let power = sample.power, power.isFinite else { previous = nil; continue }
                        let point = CGPoint(x: size.width * sample.receivedAt.timeIntervalSince(first.receivedAt) / duration,
                                            y: size.height * (1 - (power - minimum) / span))
                        if let previous, sample.receivedAt > previous,
                           sample.receivedAt.timeIntervalSince(previous) <= 5 { path.addLine(to: point) }
                        else { path.move(to: point) }
                        previous = sample.receivedAt
                    }
                    context.stroke(path, with: .color(AppTheme.accent), lineWidth: 2)
                }.frame(height: 140)
                Text(String(format: "%.0f – %.0f W", values.min() ?? 0, values.max() ?? 0))
                    .font(.caption).monospacedDigit()
                Text("按接收时间绘制历史值；缺失功率和超过 5 秒的间隙不连线。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Text("等待有效功率样本…").foregroundStyle(.secondary).frame(minHeight: 140) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding().glassCard()
    }
}
