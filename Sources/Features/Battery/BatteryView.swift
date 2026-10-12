import ANTuRideDomain
import SwiftUI

/// 电池 Tab 独占导航栈。连接管理统一在设置 → 蓝牙设备。
@MainActor
struct BatteryView: View {
    @EnvironmentObject private var bms: BmsBluetoothService
    @StateObject private var layout = ParameterLayoutStore(page: .battery)
    @State private var availableMetricIDs = Set(ParameterCatalog.metrics(for: .battery)
        .filter { !ParameterCatalog.isChannel($0.id) }.map(\.id))

    var body: some View {
        NavigationStack {
            ParameterCardPage(store: layout, leadingContent: AnyView(connectionContent),
                              availableMetricIDs: availableMetricIDs) { placement in
                AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
                    let readout = DeviceParameterReadout.read(battery: currentSnapshot(at: context.date),
                                                              metricID: placement.id)
                    AppMetricCard(title: readout.title, value: readout.value, unit: readout.unit,
                                  detail: readout.detail, prominent: placement.size == .hero)
                })
            }
            .navigationTitle("电池")
            .onAppear { includeReportedChannels() }
            .onChange(of: reportedChannelCounts) { _ in includeReportedChannels() }
        }
    }

    /// Timeline 只更新数值与有效性，不重建目录或每秒保存布局。
    private var connectionContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lastSnapshot = bms.latestSnapshot
            let freshness = BmsFreshnessEvaluator().evaluate(snapshot: lastSnapshot, now: context.date)
            let snapshot = bms.state == .ready && freshness.level == .fresh ? lastSnapshot : nil
            VStack(alignment: .leading, spacing: 12) {
                Text("BMS 连接").font(.headline)
                row("连接状态", connectionText)
                    .accessibilityIdentifier("battery.connection.status")
                row("设备名称", deviceName)
                row("BMS 状态", snapshot?.statusText ?? "--")
                Label(dataStatus(freshness), systemImage: snapshot == nil ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(snapshot == nil ? AppTheme.warning : AppTheme.success)
                LabeledContent("最后有效数据时间（仅供排查）") {
                    if let date = lastSnapshot?.receivedAt {
                        Text(date, format: .dateTime.year().month().day().hour().minute().second())
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("--")
                    }
                }
                if snapshot == nil {
                    Text(unavailableMessage(freshness))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("battery.noData")
                } else if let snapshot {
                    if snapshot.cellVoltagesMillivolts.isEmpty {
                        Text("BMS 未上报单体数据").foregroundStyle(.secondary)
                    }
                    if snapshot.temperatures.isEmpty {
                        Text("BMS 未上报温度探头").foregroundStyle(.secondary)
                    }
                }
                if let error = bms.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.danger)
                }
                Text("仅展示 BMS 已上报字段。缺失、断开或超过 5 秒未更新时，实时值显示 --。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var reportedChannelCounts: [Int] {
        [bms.latestSnapshot?.cellVoltagesMillivolts.count ?? 0, bms.latestSnapshot?.temperatures.count ?? 0]
    }

    private func includeReportedChannels() {
        let counts = reportedChannelCounts
        let channels = ParameterCatalog.reportedChannels(cellCount: counts[0], probeCount: counts[1])
        availableMetricIDs = Set(layout.catalog.filter { !ParameterCatalog.isChannel($0.id) }.map(\.id))
            .union(channels.map(\.id))
        layout.includeReportedChannels(cellCount: counts[0], probeCount: counts[1])
    }

    private func currentSnapshot(at now: Date) -> BmsSnapshot? {
        let lastSnapshot = bms.latestSnapshot
        let freshness = BmsFreshnessEvaluator().evaluate(snapshot: lastSnapshot, now: now)
        return bms.state == .ready && freshness.level == .fresh ? lastSnapshot : nil
    }

    private var deviceName: String {
        guard let name = bms.connectedDeviceName, !name.isEmpty else { return "--" }
        return name
    }

    private var connectionText: String {
        switch bms.state {
        case .idle: return "未连接"
        case .poweredOff: return "蓝牙不可用"
        case .scanning: return "扫描中"
        case .connecting: return "连接中"
        case .discovering: return "发现服务中"
        case .ready: return "已连接"
        case .reconnecting: return "重连中"
        case .disconnected: return "已断开"
        }
    }

    private func dataStatus(_ freshness: BmsDataFreshness) -> String {
        guard bms.state == .ready else { return "实时数据不可用" }
        switch freshness.level {
        case .noData: return "等待 BMS 数据"
        case .fresh: return "数据有效 · 5 秒内更新"
        case .stale: return "数据已过期"
        }
    }

    private func unavailableMessage(_ freshness: BmsDataFreshness) -> String {
        guard bms.state == .ready else { return "请前往设置 → 蓝牙设备" }
        if freshness.level == .stale {
            return "超过 5 秒未收到有效数据，实时值已隐藏。请前往设置 → 蓝牙设备检查连接。"
        }
        return "暂无 BMS 数据，等待有效帧。请前往设置 → 蓝牙设备检查连接。"
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}
