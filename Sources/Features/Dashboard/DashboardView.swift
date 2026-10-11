import ANTuRideDomain
import Charts
import SwiftUI

/// 首页只显示已保存布局的驾驶参数；连接与行程操作分别位于设备和行程 Tab。
@MainActor
struct DashboardView: View {
    @EnvironmentObject private var bms: BmsBluetoothService
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var rangeService: RangeService
    @EnvironmentObject private var controller: ControllerBluetoothService
    @EnvironmentObject private var driving: DrivingSettingsStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroValueSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title2) private var primaryValueSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var compactValueSize: CGFloat = 20
    // 与设置编辑器共用同一偏好键；保存后即使 Tab 未重建也会刷新。
    @AppStorage(HomeParameterPrefs.key) private var storedLayout = ""

    private var homeConfig: HomeParameterConfig {
        HomeParameterPrefs.decode(storedLayout) ?? .androidDefault
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let freshness = BmsFreshnessEvaluator().evaluate(snapshot: bms.latestSnapshot, now: context.date)
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                                        count: geometry.size.width >= 600
                                            && !dynamicTypeSize.isAccessibilitySize
                                            && driving.settings.valueScale < 1.5 ? 2 : 1)
                    ScrollView {
                        VStack(spacing: 12) {
                            if homeConfig.usesSlotLayout {
                                slotDashboard(freshness: freshness, size: geometry.size)
                            } else if homeConfig.visibleCardIDs.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("没有显示的首页参数").foregroundStyle(.secondary)
                                    rangeLink
                                }
                            } else {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(homeConfig.visibleCardIDs) { id in
                                        parameterCard(id, freshness: freshness)
                                            .accessibilityIdentifier("dashboard.card.\(id.rawValue)")
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                    .accessibilityIdentifier("dashboard.parameter-content")
                    .background(AppTheme.background)
                }
            }
            // 仅根页隐藏导航栏，不忽略状态栏、刘海或 Tab 的系统安全区。
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var rangeLink: some View {
        NavigationLink {
            RangeView()
                .toolbar(.visible, for: .navigationBar)
        } label: {
            Label("续航", systemImage: "gauge.with.dots.needle.33percent")
                .font(.subheadline)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("综合续航")
        .accessibilityIdentifier("dashboard.range")
    }

    /// 兼容已保存的旧版十卡片布局，不因切换到槽位布局而丢失用户偏好。
    @ViewBuilder
    private func parameterCard(_ id: HomeParameterCardID, freshness: BmsDataFreshness) -> some View {
        let showsRangeLink = homeConfig.visibleCardIDs.first == id
        switch id {
        case .currentChart:
            BmsHistoryChartCard(history: bms.snapshotHistory, metric: .current) {
                if showsRangeLink { rangeLink }
            }
        case .status:
            VStack(alignment: .leading, spacing: 8) {
                if showsRangeLink { rangeLink }
                StatusChipsCard(snapshot: freshness.level == .fresh ? bms.latestSnapshot : nil, isStale: freshness.level == .stale)
            }
        case .capacityAndHealth:
            VStack(spacing: 8) {
                slotCard(.init(slotId: id.rawValue, metricId: "bms_capacity"), freshness: freshness, showsRangeLink: showsRangeLink)
                slotCard(.init(slotId: "soh", metricId: "bms_soh"), freshness: freshness)
            }
        default:
            slotCard(.init(slotId: id.rawValue, metricId: legacyMetricID(id)), freshness: freshness,
                     fontSize: primaryValueSize, showsRangeLink: showsRangeLink)
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
            BmsHistoryChartCard(history: bms.snapshotHistory, metric: .power) { EmptyView() }
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
            }
            .padding()
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func slotDashboard(freshness: BmsDataFreshness, size: CGSize) -> some View {
        let wide = size.width >= 600
            && size.width > size.height
            && !dynamicTypeSize.isAccessibilitySize
            && driving.settings.valueScale < 1.5
        if wide {
            HStack(alignment: .top, spacing: 12) {
                topSlotCards(freshness: freshness)
                    .frame(maxWidth: .infinity)
                powerGraphic
                    .frame(maxWidth: .infinity)
            }
        } else {
            topSlotCards(freshness: freshness)
            powerGraphic
        }
        bottomSlots(in: .vehicle, freshness: freshness)
        bottomSlots(in: .controller, freshness: freshness)
    }

    private func topSlotCards(freshness: BmsDataFreshness) -> some View {
        VStack(spacing: 8) {
            ForEach(HomeParameterSlotDefinition.heroIDs, id: \.self) { slotId in
                if let metricId = homeConfig.metricId(for: slotId) {
                    slotCard(HomeParameterAssignment(slotId: slotId, metricId: metricId), freshness: freshness,
                             fontSize: slotId == "top_speed" ? heroValueSize : primaryValueSize,
                             showsRangeLink: slotId == "top_speed")
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                                count: dynamicTypeSize.isAccessibilitySize || driving.settings.valueScale >= 1.5 ? 1 : 2)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(HomeParameterSlotDefinition.gridIDs, id: \.self) { slotId in
                    if let metricId = homeConfig.metricId(for: slotId) {
                        slotCard(HomeParameterAssignment(slotId: slotId, metricId: metricId), freshness: freshness,
                                 fontSize: primaryValueSize)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bottomSlots(in region: HomeParameterRegion, freshness: BmsDataFreshness) -> some View {
        let assignments = homeConfig.assignments(in: region)
        let rows = HomeParameterLayout.rows(assignments, in: region)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(region.title).font(.headline)
                if dynamicTypeSize.isAccessibilitySize || driving.settings.valueScale >= 1.5 {
                    LazyVStack(spacing: 8) {
                        ForEach(assignments) { assignment in
                            slotCard(assignment, freshness: freshness)
                        }
                    }
                } else {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(rows.indices, id: \.self) { index in
                            let row = rows[index]
                            let used = row.reduce(0) { $0 + HomeParameterLayout.span($1, in: region) }
                            GridRow(alignment: .top) {
                                ForEach(row) { assignment in
                                    slotCard(assignment, freshness: freshness)
                                        .gridCellColumns(HomeParameterLayout.span(assignment, in: region))
                                }
                                ForEach(0..<(3 - used), id: \.self) { _ in
                                    Color.clear
                                        .gridCellUnsizedAxes([.horizontal, .vertical])
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func slotCard(_ assignment: HomeParameterAssignment, freshness: BmsDataFreshness,
                          fontSize: CGFloat? = nil, showsRangeLink: Bool = false) -> some View {
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
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    parameterTitle(readout.title)
                    if showsRangeLink { Spacer(minLength: 8); rangeLink }
                }
                VStack(alignment: .leading, spacing: 4) {
                    parameterTitle(readout.title)
                    if showsRangeLink { rangeLink }
                }
            }
            Text(readout.value)
                .font(.system(size: (fontSize ?? compactValueSize) * driving.settings.valueScale,
                              weight: .semibold, design: .rounded))
                .foregroundStyle(metricColor(assignment.metricId, snapshot: snapshot))
                .monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize || driving.settings.valueScale >= 1.5 || readout.unit.isEmpty ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.75)
                .accessibilityLabel("\(readout.title)，\(readout.value) \(readout.unit)")
            if !readout.unit.isEmpty { Text(readout.unit).font(.caption).foregroundStyle(AppTheme.accent) }
            if readout.value == "--", HomeParameterMetricDefinition.definition(for: assignment.metricId)?.source == .bms {
                Text(bms.state != .ready ? "BMS 未连接" : freshness.level == .stale ? "数据已过期" : "等待 BMS 数据")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if assignment.metricId == "app_gps_speed", let fix = location.lastFix, let speed = fix.speedKmhForDisplay,
               location.isUpdating, Date().timeIntervalSince(fix.timestamp) >= 0,
               Date().timeIntervalSince(fix.timestamp) <= 10 {
                ProgressView(value: min(1, max(0, speed) / driving.settings.powerHeaderSpeedBaseKmh))
                    .tint(metricColor(assignment.metricId, snapshot: snapshot))
            }
            if driving.settings.showTextDescriptions && assignment.metricId == "app_range" {
                Text(rangeService.reasonText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("dashboard.slot.\(assignment.slotId)")
    }

    private func parameterTitle(_ title: String) -> some View {
        Text(driving.settings.showTextDescriptions ? title : title.components(separatedBy: " · ").last ?? title)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

/// 与行程图表相同：真实时间轴、独立连续区间与可见孤立点，不补造功率。
enum BmsHistoryMetric: Equatable {
    case current, power

    var title: String { self == .current ? "历史电流曲线" : "历史功率曲线" }
    var unit: String { self == .current ? "A" : "W" }

    func value(in snapshot: BmsSnapshot) -> Double? {
        let value: Double? = self == .current ? snapshot.current : snapshot.power
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
}

struct BmsHistoryChartPoint: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    let value: Double
    let series: Int

    static func makePoints(history: [BmsSnapshot], metric: BmsHistoryMetric) -> [Self] {
        var points: [Self] = []
        var previous: Date?
        var series = 0
        for (index, snapshot) in history.enumerated() {
            guard snapshot.receivedAt.timeIntervalSinceReferenceDate.isFinite,
                  let value = metric.value(in: snapshot) else {
                previous = nil
                continue
            }
            let interval = previous.map { snapshot.receivedAt.timeIntervalSince($0) }
            if let interval, interval > 0, interval <= 5 {
                // 仅递增且在历史连续性阈值内的样本共用 series。
            } else {
                series += 1
            }
            points.append(Self(id: index, timestamp: snapshot.receivedAt, value: value, series: series))
            previous = snapshot.receivedAt
        }
        return points
    }
}

private struct BmsHistoryChartCard<Accessory: View>: View {
    let history: [BmsSnapshot]
    let metric: BmsHistoryMetric
    let accessory: Accessory
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 180

    init(history: [BmsSnapshot], metric: BmsHistoryMetric, @ViewBuilder accessory: () -> Accessory) {
        self.history = history
        self.metric = metric
        self.accessory = accessory()
    }

    var body: some View {
        let points = BmsHistoryChartPoint.makePoints(history: history, metric: metric)
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("\(metric.title) · \(metric.unit)").font(.headline)
                    Spacer(minLength: 8)
                    accessory
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(metric.title) · \(metric.unit)").font(.headline)
                    accessory
                }
            }
            if points.isEmpty {
                Text("等待有效\(metric == .current ? "电流" : "功率")样本…")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("接收时间", point.timestamp), y: .value(metric.unit, point.value),
                             series: .value("连续区间", point.series))
                        .interpolationMethod(.linear)
                        .foregroundStyle(AppTheme.accent)
                    PointMark(x: .value("接收时间", point.timestamp), y: .value(metric.unit, point.value))
                        .foregroundStyle(AppTheme.accent)
                        .symbolSize(12)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .chartXAxisLabel("接收时间")
                .chartYAxisLabel(metric.unit)
                .chartLegend(.hidden)
                .frame(height: chartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metric.title)
                .accessibilityValue(summary(points))
                .accessibilityIdentifier("dashboard.chart.\(metric == .current ? "current" : "power")")
                Text(summary(points))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("历史接收值；缺失/无效、非递增时间及超过 5 秒的间隙不连线，孤立样本仅显示点。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func summary(_ points: [BmsHistoryChartPoint]) -> String {
        guard let first = points.map(\.timestamp).min(), let latest = points.max(by: { $0.timestamp < $1.timestamp }),
              let minimum = points.map(\.value).min(), let maximum = points.map(\.value).max() else {
            return "没有有效样本"
        }
        let format = Date.FormatStyle.dateTime.hour().minute().second()
        let precision = metric == .current ? 1 : 0
        let range = String(format: "%.*f–%.*f %@", precision, minimum, precision, maximum, metric.unit)
        let lastValue = String(format: "%.*f %@", precision, latest.value, metric.unit)
        let breaks = max(0, Set(points.map(\.series)).count - 1)
        return "\(first.formatted(format))–\(latest.timestamp.formatted(format))；\(points.count) 个有效样本；范围 \(range)；末次 \(lastValue)；\(breaks) 处断线，\(history.count - points.count) 个缺失或无效样本。"
    }
}
