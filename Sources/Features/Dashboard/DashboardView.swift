import ANTuRideDomain
import Charts
import SwiftUI

/// 页面内编辑布局；曲线固定在重点参数和来源分类之间，连接/行程操作不回到首页。
@MainActor
struct DashboardView: View {
    @EnvironmentObject private var bms: BmsBluetoothService
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var rangeService: RangeService
    @EnvironmentObject private var controller: ControllerBluetoothService
    @EnvironmentObject private var driving: DrivingSettingsStore
    @StateObject private var layout = ParameterLayoutStore(page: .dashboard)
    @State private var showingRange = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let freshness = BmsFreshnessEvaluator().evaluate(snapshot: bms.latestSnapshot, now: context.date)
                ParameterCardPage(store: layout, middleContent: AnyView(powerGraphic),
                                  valueScale: driving.settings.valueScale) { placement in
                    AnyView(metricCard(placement, freshness: freshness, now: context.date))
                }
            }
            // 仅根页隐藏导航栏，不忽略状态栏、刘海或 Tab 的系统安全区。
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingRange) {
                RangeView().toolbar(.visible, for: .navigationBar)
            }
        }
    }

    private var rangeLink: some View {
        // 单元格的 UIHostingConfiguration 不是导航根；路由交由外层 NavigationStack。
        Button { showingRange = true } label: {
            Label("续航", systemImage: "gauge.with.dots.needle.33percent")
                .font(.subheadline).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("综合续航")
        .accessibilityIdentifier("dashboard.range")
    }

    @ViewBuilder
    private var powerGraphic: some View {
        if driving.settings.defaultPowerDisplayMode == .curve {
            BmsHistoryChartCard(history: bms.snapshotHistory, metric: .power) { rangeLink }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack { Text("实时功率").font(.headline); Spacer(); rangeLink }
                    VStack(alignment: .leading) { Text("实时功率").font(.headline); rangeLink }
                }
                if let snapshot = bms.latestSnapshot, bms.state == .ready,
                   BmsFreshnessEvaluator().evaluate(snapshot: snapshot, now: Date()).level == .fresh,
                   let power = snapshot.power, power.isFinite {
                    let base = power >= 0 ? driving.settings.dischargeBaseW : driving.settings.chargeBaseW
                    ProgressView(value: min(1, abs(power) / base))
                        .tint(metricColor("bms_power", snapshot: snapshot))
                    Text(String(format: "%.0f W / %.0f W", power, base)).monospacedDigit()
                } else { Text("--").foregroundStyle(.secondary) }
            }
            .padding().background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func metricCard(_ placement: ParameterPlacement, freshness: BmsDataFreshness, now: Date) -> some View {
        let snapshot = bms.state == .ready && freshness.level == .fresh ? bms.latestSnapshot : nil
        let gpsSpeed: Double? = {
            guard location.isUpdating, let fix = location.lastFix,
                  now.timeIntervalSince(fix.timestamp) >= 0, now.timeIntervalSince(fix.timestamp) <= 10 else { return nil }
            return fix.speedKmhForDisplay
        }()
        let telemetry = freshControllerTelemetry(now: now)
        let readout = HomeParameterReadout.read(
            metricId: placement.metricID, snapshot: snapshot, gpsSpeedKmh: gpsSpeed,
            rangeKm: rangeService.status == .valid ? rangeService.prediction?.predictedRangeKm : nil,
            consumptionWhPerKm: rangeService.status == .valid ? rangeService.effectiveWhPerKm : nil,
            controller: telemetry, settings: driving.settings,
            averageSpeedKmh: rangeService.averageSpeedKmh, referenceKmPerAh: rangeService.referenceKmPerAh,
            bmsRSSI: bms.rssiReceivedAt.flatMap { date in
                let age = now.timeIntervalSince(date)
                return bms.state == .ready && age >= 0 && age <= 10 ? bms.rssi : nil
            }
        )
        let source = ParameterCatalog.descriptor(placement.metricID, on: .dashboard)?.source
        let detail: String? = {
            if readout.value == "--" {
                if source == .bms {
                    return bms.state != .ready ? "BMS 未连接" : freshness.level == .stale ? "数据已过期" : "等待 BMS 数据"
                }
                if source == .controller {
                    return controller.state != .ready ? "控制器未连接" : "等待有效控制器数据 / 数据已过期"
                }
                if placement.metricID == "app_range" { return rangeService.reasonText }
                return "等待有效数据"
            }
            return driving.settings.showTextDescriptions && placement.metricID == "app_range" ? rangeService.reasonText : nil
        }()
        // 混合来源的首页始终标明真实来源；说明开关只控制辅助说明。
        let title = readout.title
        return VStack(alignment: .leading, spacing: 0) {
            AppMetricCard(title: title, value: readout.value, unit: readout.unit, detail: detail,
                          color: metricColor(placement.metricID, snapshot: snapshot),
                          prominent: placement.size == .hero, valueScale: driving.settings.valueScale)
            if placement.metricID == "app_gps_speed", let speed = gpsSpeed {
                ProgressView(value: min(1, max(0, speed) / driving.settings.powerHeaderSpeedBaseKmh))
                    .tint(metricColor(placement.metricID, snapshot: snapshot))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func freshControllerTelemetry(now: Date) -> MotorControllerTelemetry? {
        guard controller.state == .ready, let snapshot = controller.latestSnapshot else { return nil }
        let age = now.timeIntervalSince(snapshot.receivedAt)
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
                    func state(_ on: Bool?) -> String { on.map { $0 ? "开" : "关" } ?? "未知" }
                    value = "充电\(state(snapshot.chargeMOSOn)) · 放电\(state(snapshot.dischargeMOSOn))"
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
