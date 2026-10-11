import ANTuRideDomain
import Charts
import SwiftUI

/// 当前会话与本地保存的行程；重启后的检查点明确标记为未完成。
@MainActor
struct TripHistoryView: View {
    @EnvironmentObject private var tripSession: TripSessionService
    @State private var pendingDeletion: [UUID] = []
    @State private var showingDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section("当前行程") {
                    TripSessionCard()
                }
                if let trip = tripSession.pendingSaveTrip {
                    Section("待保存行程") {
                        Text("上一段行程尚未保存，重试保存或查看详情导出后再开始新行程。")
                            .font(.footnote).foregroundStyle(AppTheme.warning)
                        Button("重试保存") { tripSession.retryPendingSave() }
                            .frame(minHeight: 44)
                        NavigationLink("查看待保存行程") { TripDetailView(trip: trip) }
                    }
                }
                if let error = tripSession.historyError {
                    Section("读取失败") {
                        Text(error).foregroundStyle(AppTheme.danger)
                        Button("重新读取") { tripSession.reloadHistory() }
                            .frame(minHeight: 44)
                    }
                }
                Section("已保存行程") {
                    if tripSession.savedTrips.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("暂无行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.headline)
                            Text("在本页顶部开始并结束一次行程后，可在这里查看记录。")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("trip-history-empty")
                    } else {
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
                }
            }
            .listStyle(.insetGrouped)
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
        }
    }
}

/// 仅读取共享服务并转发按钮事件；切换 Tab 不启停会话、不改变锁屏或保存语义。
@MainActor
private struct TripSessionCard: View {
    @EnvironmentObject private var tripSession: TripSessionService

    private var isActive: Bool { tripSession.state == .recording || tripSession.state == .suspended }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    status
                    Spacer(minLength: 8)
                    sessionAction
                }
                VStack(alignment: .leading, spacing: 8) {
                    status
                    sessionAction
                }
            }
            if isActive {
                LabeledContent("已记录里程", value: TripFormatters.distance(tripSession.liveDistanceMeters,
                    locationCount: tripSession.liveSegments.reduce(0) { $0 + $1.locationCount }))
                LabeledContent("已记录净能耗", value: TripFormatters.energy(tripSession.liveEnergyWh,
                    sampleCount: tripSession.liveSegments.reduce(0) { $0 + $1.energySampleCount }))
                Text("锁屏按现有规则暂停并标记区间；暂停和数据缺口不补算里程或能耗。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("开始行程后记录 GPS 速度、里程与 BMS 能耗；没有有效采样的指标显示 --，不是零。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = tripSession.lastError {
                Text(error).font(.footnote).foregroundStyle(AppTheme.danger)
            }
        }
        .monospacedDigit()
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip-session.card")
    }

    private var status: some View {
        Label(statusText, systemImage: tripSession.state == .suspended ? "lock" : isActive ? "record.circle" : "point.topleft.down.to.point.bottomright.curvepath")
            .font(.headline)
            .foregroundStyle(tripSession.state == .suspended ? AppTheme.warning : AppTheme.accent)
    }

    private var statusText: String {
        switch tripSession.state {
        case .idle: return "尚未开始行程"
        case .recording: return "行程记录中"
        case .suspended: return "已暂停（锁屏）"
        case .finished: return "行程已结束"
        }
    }

    @ViewBuilder
    private var sessionAction: some View {
        if isActive {
            Button { tripSession.stopTrip() } label: {
                Text("结束行程").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("trip-session.stop")
        } else if tripSession.state == .idle {
            Button { tripSession.startTrip() } label: {
                Text("开始行程").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tripSession.pendingSaveTrip != nil)
            .accessibilityIdentifier("trip-session.start")
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
            if hasSamples {
                TripChartsSection(trip: trip)
            }
            Section("本地文件") {
                Text(trip.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                Button("导出行程 JSON") { export(.json) }
                    .accessibilityIdentifier("trip-export")
                Button("导出逐样本 CSV") { export(.csv) }
                    .disabled(!hasSamples)
                    .accessibilityIdentifier("trip-export-csv")
                if !hasSamples {
                    Text("此档案没有逐样本数据；可导出 JSON，不补造 CSV 样本或地图轨迹。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("导出文件长期保存在本机 Documents/Exports，关闭分享或删除行程不会删除导出副本。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let exportURL {
                    Text(exportURL.path).font(.caption).textSelection(.enabled)
                    Button("分享上次导出") { showingExport = true }
                }
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

    private var hasSamples: Bool {
        trip.segments.contains { !($0.samples?.isEmpty ?? true) }
    }

    private func export(_ format: TripStore.ExportFormat) {
        do {
            // 直接从详情快照导出：待保存/保存失败行程仍可取回数据。
            exportURL = try TripStore().export(trip, format: format)
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
    @State private var segmentPage = 0
    @State private var samplePage = 0
    @State private var windowPage = 0

    private struct ChartPoint: Identifiable {
        let id: Int
        let timestamp: Date
        let value: Double
        let series: Int
    }

    private func chartPoints(segment: TripSegment, range: Range<Int>) -> [ChartPoint] {
        // 复用领域层断线规则，但只输入当前区间当前页，最多渲染 100 点。
        let pageSegment = TripSegment(
            kind: segment.kind, startedAt: segment.startedAt, endedAt: segment.endedAt,
            distanceMeters: segment.distanceMeters, energyWh: segment.energyWh,
            locationCount: segment.locationCount, energySampleCount: segment.energySampleCount,
            invalidLocationCount: segment.invalidLocationCount,
            samples: Array((segment.samples ?? [])[range])
        )
        let pageTrip = Trip(startedAt: trip.startedAt, segments: [pageSegment])
        var points: [ChartPoint] = []
        for (series, samples) in pageTrip.chartSegments(for: metric).enumerated() {
            for sample in samples {
                if let value = metric.value(in: sample) {
                    points.append(ChartPoint(id: points.count, timestamp: sample.timestamp, value: value, series: series))
                }
            }
        }
        return points
    }

    var body: some View {
        let segmentRange = TripStore.pageRange(count: trip.segments.count, page: segmentPage, pageSize: 1)
        if let segmentIndex = segmentRange.first {
            let segment = trip.segments[segmentIndex]
            let samples = segment.samples ?? []
            let range = TripStore.pageRange(count: samples.count, page: samplePage)
            Section {
                TripPageControls(title: "区间", count: trip.segments.count, pageSize: 1, page: $segmentPage)
                Text("第 \(segmentIndex + 1) 段 · \(TripFormatters.kind(segment.kind))")
                TripPageControls(title: "样本", count: samples.count, pageSize: 100, page: $samplePage)
            } header: {
                Text("分段样本浏览")
            } footer: {
                Text("每页最多 100 个原始样本，曲线只显示本页，不跨页或跨区间连线。")
            }
            Section {
                Picker("曲线指标", selection: $metric) {
                    ForEach(TripMetric.allCases, id: \.self) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("trip-chart-metric")
                let points = chartPoints(segment: segment, range: range)
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
            Section("逐样本 · 当前页") {
                if samples.isEmpty {
                    Text(segment.samples == nil ? "旧档案没有逐样本数据" : "本区间没有样本")
                        .foregroundStyle(.secondary)
                }
                ForEach(range, id: \.self) { index in
                    TripSampleRow(index: index + 1, sample: samples[index])
                }
            }
        }
        Section {
            Picker("时间窗口", selection: $windowMinutes) {
                ForEach(Trip.supportedWindowMinutes, id: \.self) { minutes in
                    Text("\(minutes) 分钟").tag(minutes)
                }
            }.pickerStyle(.segmented)
            let summaries = trip.windowSummaries(minutes: windowMinutes)
            DisclosureGroup("查看 \(summaries.count) 个窗口") {
                TripPageControls(title: "窗口", count: summaries.count, pageSize: 20, page: $windowPage)
                ForEach(TripStore.pageRange(count: summaries.count, page: windowPage, pageSize: 20), id: \.self) { index in
                    TripWindowRow(summary: summaries[index])
                }
            }
        } header: {
            Text("窗口摘要")
        } footer: {
            Text("按记录跨度划分，暂停/缺口仍占分母；末窗按实际时长。跨窗口仅按已积分区间比例分摊。GPS/BMS 单独覆盖，Wh/km 只取共同覆盖部分；-- 表示没有证据，不是零。每页最多 20 个窗口。")
        }
        .onChange(of: windowMinutes) { _ in windowPage = 0 }
        .onChange(of: segmentPage) { _ in samplePage = 0 }
    }
}

/// 有界切页而非持续追加；最后一页/空档案/页码变化都通过同一范围规则处理。
private struct TripPageControls: View {
    let title: String
    let count: Int
    let pageSize: Int
    @Binding var page: Int

    var body: some View {
        let range = TripStore.pageRange(count: count, page: page, pageSize: pageSize)
        let current = range.lowerBound / pageSize
        let pages = count == 0 ? 0 : (count - 1) / pageSize + 1
        VStack(alignment: .leading, spacing: 8) {
            Text(count == 0 ? "\(title)：0 条" : "\(title)：\(range.lowerBound + 1)–\(range.upperBound) / \(count) · 第 \(current + 1)/\(pages) 页")
                .font(.caption).monospacedDigit()
            HStack {
                Button("上一页") { page = current - 1 }
                    .disabled(range.isEmpty || current == 0)
                Spacer()
                Button("下一页") { page = current + 1 }
                    .disabled(range.isEmpty || range.upperBound == count)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct TripSampleRow: View {
    let index: Int
    let sample: TripSample

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("#\(index) · \(sample.timestamp, format: .dateTime.hour().minute().second())")
                .font(.subheadline)
            Text("GPS \(validity(sample.gpsValid)) · BMS \(validity(sample.bmsValid))")
                .foregroundStyle(.secondary)
            Text("速度 \(number(sample.speedMetersPerSecond, unit: "m/s")) · 电压 \(number(sample.voltageVolts, unit: "V"))")
            Text("电流 \(number(sample.currentAmps, unit: "A")) · 功率 \(number(sample.powerWatts, unit: "W"))")
            Text("里程 \(number(sample.distanceMeters, unit: "m")) / \(number(sample.locationIntervalSeconds, unit: "s")) · 能耗 \(number(sample.energyWh, unit: "Wh")) / \(number(sample.energyIntervalSeconds, unit: "s"))")
            Text("纬度 \(number(sample.latitude, unit: "")) · 经度 \(number(sample.longitude, unit: ""))")
        }.font(.caption).monospacedDigit().padding(.vertical, 4)
    }

    private func validity(_ value: Bool?) -> String {
        value.map { $0 ? "有效" : "无效" } ?? "未采集"
    }

    private func number(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "--" }
        return value.formatted(.number.precision(.fractionLength(3))) + (unit.isEmpty ? "" : " " + unit)
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
