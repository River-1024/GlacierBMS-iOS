import ANTuRideDomain
import Charts
import SwiftUI

/// 本地保存的行程；未结束会话只在仪表盘显示，重启后的检查点明确标记为未完成。
struct TripHistoryView: View {
    @EnvironmentObject private var tripSession: TripSessionService
    @State private var pendingDeletion: [UUID] = []
    @State private var showingDeletion = false

    var body: some View {
        NavigationStack {
            Group {
                if let error = tripSession.historyError, tripSession.savedTrips.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(AppTheme.danger)
                        Button("重新读取") { tripSession.reloadHistory() }
                    }.padding()
                } else if tripSession.savedTrips.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.largeTitle).foregroundStyle(AppTheme.accent)
                        Text("暂无行程").font(.title3.weight(.semibold))
                        Text("在仪表盘开始并结束一次行程后，可在这里查看记录。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("trip-history-empty")
                } else {
                    List {
                        ForEach(tripSession.savedTrips, id: \.id) { trip in
                            NavigationLink {
                                TripDetailView(trip: trip)
                            } label: {
                                TripRow(trip: trip)
                            }
                            .accessibilityIdentifier("trip-row-\(trip.id.uuidString)")
                        }
                        .onDelete { offsets in
                            pendingDeletion = offsets.map { tripSession.savedTrips[$0].id }
                            showingDeletion = true
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("行程")
            .toolbar {
                if !tripSession.savedTrips.isEmpty { EditButton() }
            }
            .confirmationDialog("删除所选行程？本机文件删除后无法恢复。", isPresented: $showingDeletion, titleVisibility: .visible) {
                Button("删除行程", role: .destructive) {
                    pendingDeletion.forEach { tripSession.deleteTrip(id: $0) }
                    pendingDeletion = []
                }
                Button("取消", role: .cancel) { pendingDeletion = [] }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let error = tripSession.historyError ?? tripSession.lastError {
                        Text(error).font(.footnote).foregroundStyle(AppTheme.danger)
                    }
                    if let trip = tripSession.pendingSaveTrip {
                        HStack {
                            Button("重试保存") { tripSession.retryPendingSave() }
                            Spacer()
                            NavigationLink("查看待保存行程") { TripDetailView(trip: trip) }
                        }.font(.footnote)
                    }
                }
                .padding().frame(maxWidth: .infinity).background(AppTheme.background)
            }
        }
    }

}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trip.startedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { metrics }
                VStack(alignment: .leading, spacing: 4) { metrics }
            }
            .font(.subheadline).monospacedDigit()
            if trip.endedAt == nil {
                Text("未完成 · 仅保存到上次检查点")
                    .font(.caption).foregroundStyle(AppTheme.warning)
            }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var metrics: some View {
        Text(TripFormatters.distance(trip.totalDistanceMeters, locationCount: trip.segments.reduce(0) { $0 + $1.locationCount })).foregroundStyle(AppTheme.accent)
        Label(TripFormatters.duration(trip.durationSeconds), systemImage: "clock")
        Text(TripFormatters.energy(trip.totalEnergyWh, sampleCount: trip.segments.reduce(0) { $0 + $1.energySampleCount }))
            .foregroundStyle(.secondary)
    }
}

struct TripDetailView: View {
    let trip: Trip
    @State private var exportURL: URL?
    @State private var showingExport = false
    @State private var exportError: String?

    var body: some View {
        List {
            Section("行程概要") {
                Text(TripFormatters.distance(trip.totalDistanceMeters, locationCount: trip.segments.reduce(0) { $0 + $1.locationCount }))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                LabeledContent("记录跨度", value: TripFormatters.duration(trip.durationSeconds))
                LabeledContent("已记录净能耗", value: TripFormatters.energy(trip.totalEnergyWh, sampleCount: trip.segments.reduce(0) { $0 + $1.energySampleCount }))
            }
            Section("时间") {
                LabeledContent("开始") { timestamp(trip.startedAt) }
                if let endedAt = trip.endedAt {
                    LabeledContent("结束") { timestamp(endedAt) }
                } else {
                    Text("未完成：仅保留上次保存的检查点，不代表行程已经结束。")
                        .foregroundStyle(AppTheme.warning)
                }
            }
            Section {
                if trip.segments.isEmpty {
                    Text("没有已保存的采样区间").foregroundStyle(.secondary)
                }
                ForEach(Array(trip.segments.enumerated()), id: \.offset) { index, segment in
                    SegmentRow(index: index + 1, segment: segment)
                }
            } header: {
                Text("采样区间 · \(trip.segments.count) 段")
            } footer: {
                Text("暂停与缺口不补算里程或能耗。净能耗可为负（充电）；未采样显示 --。旧档案可能没有逐点数据；当前不提供地图回放。")
            }
            // legacy 档案保持原分段列表布局，不显示空图或空窗口区域。
            if !trip.samples.isEmpty {
                TripChartsSection(trip: trip)
            }
            Section("本地文件") {
                Text(trip.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                Button("导出行程 JSON", action: export)
                    .accessibilityIdentifier("trip-export")
                if let exportError { Text(exportError).foregroundStyle(AppTheme.danger) }
            }
        }
        .navigationTitle("行程详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingExport) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: .dateTime.year().month().day().hour().minute().second())
            .multilineTextAlignment(.trailing)
    }

    private func export() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // 与持久化相同的日期编码，便于 JSONDecoder 直接核验往返。
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("trip-\(trip.id.uuidString).json")
            try encoder.encode(trip).write(to: url, options: .atomic)
            exportURL = url
            exportError = nil
            showingExport = true
        } catch {
            exportError = "行程导出失败：\(error.localizedDescription)"
        }
    }
}

private struct SegmentRow: View {
    let index: Int
    let segment: TripSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("第 \(index) 段 · \(TripFormatters.kind(segment.kind))", systemImage: TripFormatters.icon(segment.kind))
                .font(.headline)
            Text("\(segment.startedAt, format: .dateTime.month().day().hour().minute().second()) → \(segment.endedAt, format: .dateTime.month().day().hour().minute().second())")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(TripFormatters.distance(segment.distanceMeters, locationCount: segment.locationCount)) · \(TripFormatters.energy(segment.energyWh, sampleCount: segment.energySampleCount))")
                .font(.subheadline).monospacedDigit()
            Text("GPS \(segment.locationCount) 点 · 能耗 \(segment.energySampleCount) 次 · 无效定位 \(segment.invalidLocationCount) 点")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}


private struct TripChartsSection: View {
    let trip: Trip
    @State private var metric: TripMetric = .speed
    @State private var windowMinutes = 3

    private struct ChartPoint: Identifiable {
        let id: Int
        let timestamp: Date
        let value: Double
        let series: Int
    }

    private var chartPoints: [ChartPoint] {
        var points: [ChartPoint] = []
        for (series, samples) in trip.chartSegments(for: metric).enumerated() {
            for sample in samples {
                if let value = metric.value(in: sample) {
                    points.append(ChartPoint(id: points.count, timestamp: sample.timestamp, value: value, series: series))
                }
            }
        }
        return points
    }

    var body: some View {
        Section {
            Picker("曲线指标", selection: $metric) {
                ForEach(TripMetric.allCases, id: \.self) { metric in
                    Text(metric.label).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("trip-chart-metric")
            let points = chartPoints
            if points.isEmpty {
                Text("没有有效的\(metric.label)采样").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("时间", point.timestamp), y: .value(metric.label, point.value),
                             series: .value("连续区间", point.series))
                        .interpolationMethod(.linear)
                        .foregroundStyle(AppTheme.accent)
                    PointMark(x: .value("时间", point.timestamp), y: .value(metric.label, point.value))
                        .foregroundStyle(AppTheme.accent)
                        .symbolSize(12)
                }
                .chartYAxisLabel(metric.unit)
                .chartLegend(.hidden)
                .frame(height: 200)
                .accessibilityIdentifier("trip-detail-chart")
            }
        } header: {
            Text("逐点曲线 · \(metric.unit)")
        } footer: {
            Text("仅展示本次输入的有效值；无效、暂停、相位切换及超时配对均断线，不沿用旧值。")
        }
        Section {
            Picker("时间窗口", selection: $windowMinutes) {
                ForEach(Trip.supportedWindowMinutes, id: \.self) { minutes in
                    Text("\(minutes) 分钟").tag(minutes)
                }
            }.pickerStyle(.segmented)
            let summaries = trip.windowSummaries(minutes: windowMinutes)
            DisclosureGroup("查看 \(summaries.count) 个窗口") {
                ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
                    TripWindowRow(summary: summary)
                }
            }
        } header: {
            Text("窗口摘要")
        } footer: {
            Text("按记录跨度划分，暂停/缺口仍占分母；末窗按实际时长。跨窗口仅按已积分区间比例分摊。GPS/BMS 单独覆盖，Wh/km 只取共同覆盖部分；-- 表示没有证据，不是零。")
        }
    }
}

private struct TripWindowRow: View {
    let summary: TripWindowSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(summary.startedAt, format: .dateTime.hour().minute().second()) → \(summary.endedAt, format: .dateTime.hour().minute().second())")
                .font(.subheadline)
            Text("GPS \(summary.gpsCoverageRatio, format: .percent.precision(.fractionLength(0))) · BMS \(summary.bmsCoverageRatio, format: .percent.precision(.fractionLength(0))) · 共同 \(summary.coverageRatio, format: .percent.precision(.fractionLength(0)))")
                .font(.caption).foregroundStyle(.secondary)
            Text("里程 \(formatted(summary.distanceMeters, unit: "m")) · 净能耗 \(formatted(summary.energyWh, unit: "Wh"))")
            Text("有效均速 \(formatted(summary.averageSpeedKmh, unit: "km/h")) · 有效均功率 \(formatted(summary.averagePowerWatts, unit: "W"))")
            Text("共同区间能耗 \(formatted(summary.whPerKm, unit: "Wh/km"))")
        }.font(.caption).monospacedDigit().padding(.vertical, 4)
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "--" }
        return value.formatted(.number.precision(.fractionLength(1))) + " " + unit
    }
}

private extension TripMetric {
    var label: String {
        switch self {
        case .speed: return "速度"
        case .power: return "功率"
        case .voltage: return "电压"
        case .current: return "电流"
        }
    }
    var unit: String {
        switch self {
        case .speed: return "km/h"
        case .power: return "W"
        case .voltage: return "V"
        case .current: return "A"
        }
    }
}
