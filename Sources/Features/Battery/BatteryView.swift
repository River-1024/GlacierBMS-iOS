import ANTuRideDomain
import SwiftUI

/// 电池 Tab 独占导航栈。连接管理统一在设置 → 蓝牙设备。
struct BatteryView: View {
    @EnvironmentObject private var bms: BmsBluetoothService

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let lastSnapshot = bms.latestSnapshot
                let freshness = BmsFreshnessEvaluator().evaluate(snapshot: lastSnapshot, now: context.date)
                let snapshot = bms.state == .ready && freshness.level == .fresh ? lastSnapshot : nil
                List {
                    Section("BMS 连接") {
                        row("连接状态", connectionText)
                            .accessibilityIdentifier("battery.connection.status")
                        row("设备名称", bms.connectedDeviceName ?? "--")
                        Label(dataStatus(freshness), systemImage: snapshot == nil ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(snapshot == nil ? AppTheme.warning : AppTheme.success)
                        LabeledContent("最后有效数据时间") {
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
                        }
                    }
                    Section("电池包") {
                        row("BMS 状态", snapshot?.statusText ?? "--")
                        row("总电压", number(snapshot?.totalVoltage, unit: "V", format: BmsFormatters.voltage))
                        row("电流", number(snapshot?.current, unit: "A", format: BmsFormatters.current))
                        row("功率", number(snapshot?.power, unit: "kW", format: BmsFormatters.kilowatts))
                        row("SOC", number(snapshot?.soc, unit: "%", format: BmsFormatters.percent))
                        row("总容量", number(snapshot?.capacityAh, unit: "Ah", format: BmsFormatters.current))
                        row("剩余容量", number(snapshot?.remainingAh, unit: "Ah", format: BmsFormatters.current))
                        row("SOH", snapshot?.soh.map { "\($0)%" } ?? "--")
                        row("运行时间", BmsFormatters.runtime(snapshot?.runtimeSeconds) ?? "--")
                    }
                    Section("单体电压") {
                        row("已上报单体数量", snapshot.map { "\($0.cellVoltagesMillivolts.count) 个" } ?? "--")
                        row("最高", snapshot?.maxCellVoltageMillivolts.map(BmsFormatters.millivolts) ?? "--")
                        row("最低", snapshot?.minCellVoltageMillivolts.map(BmsFormatters.millivolts) ?? "--")
                        row("压差", snapshot?.voltageDiffMillivolts.map(BmsFormatters.millivolts) ?? "--")
                        if let lastSnapshot, !lastSnapshot.cellVoltagesMillivolts.isEmpty {
                            ForEach(lastSnapshot.cellVoltagesMillivolts.indices, id: \.self) { index in
                                row(cellTitle(index, snapshot: snapshot), snapshot.map {
                                    BmsFormatters.millivolts($0.cellVoltagesMillivolts[index])
                                } ?? "--")
                            }
                        } else {
                            row("单体电压", "--")
                            Text(snapshot == nil ? "等待有效单体数据" : "BMS 未上报单体数据")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("温度") {
                        row("最高探头温度", snapshot?.temperatures.max().map { "\($0) ℃" } ?? "--")
                        row("最低探头温度", snapshot?.temperatures.min().map { "\($0) ℃" } ?? "--")
                        if let lastSnapshot, !lastSnapshot.temperatures.isEmpty {
                            ForEach(lastSnapshot.temperatures.indices, id: \.self) { index in
                                row("探头 \(index + 1)", snapshot.map { "\($0.temperatures[index]) ℃" } ?? "--")
                            }
                        } else {
                            row("探头温度", "--")
                            Text(snapshot == nil ? "等待有效探头数据" : "BMS 未上报温度探头")
                                .foregroundStyle(.secondary)
                        }
                        row("MOS 温度", snapshot.map { "\($0.mosTemperature) ℃" } ?? "--")
                        row("均衡温度", snapshot.map { "\($0.balancerTemperature) ℃" } ?? "--")
                    }
                    Section("MOS 与均衡") {
                        row("充电 MOS", mosText(snapshot?.chargeMOSOn))
                        row("放电 MOS", mosText(snapshot?.dischargeMOSOn))
                        row("均衡状态码", snapshot?.balanceStatus.map { String($0) } ?? "--")
                        row("均衡位掩码", snapshot?.balanceMask.map { "0x" + String($0, radix: 16).uppercased() } ?? "--")
                    }
                    Section {
                        row("BMS 状态码", snapshot?.statusCode.map { String($0) } ?? "--")
                        row("有效帧字节数", snapshot.map { String($0.frameLength) } ?? "--")
                        row("未解析字节数", snapshot.map { String($0.unparsedBytes) } ?? "--")
                        if let error = bms.lastError {
                            Text(error).foregroundStyle(AppTheme.danger)
                        }
                    } header: {
                        Text("通讯诊断")
                    } footer: {
                        Text("仅展示 BMS 已上报字段。缺失、断开或超过 5 秒未更新时，实时值显示 --；最后有效数据时间仅供排查。")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(AppTheme.background)
                .navigationTitle("电池")
            }
        }
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

    /// 仅标识当前有效数据中的极值，不推断单体异常或保护阈值。
    private func cellTitle(_ index: Int, snapshot: BmsSnapshot?) -> String {
        let title = "单体 \(index + 1)"
        guard let snapshot, snapshot.cellVoltagesMillivolts.indices.contains(index) else { return title }
        let millivolts = snapshot.cellVoltagesMillivolts[index]
        var markers: [String] = []
        if millivolts == snapshot.maxCellVoltageMillivolts { markers.append("最高") }
        if millivolts == snapshot.minCellVoltageMillivolts { markers.append("最低") }
        return markers.isEmpty ? title : "\(title) · \(markers.joined(separator: " / "))"
    }

    private func mosText(_ on: Bool?) -> String {
        guard let on else { return "--" }
        return on ? "开启" : "关闭"
    }

    private func number(_ value: Double?, unit: String, format: (Double) -> String) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(format(value)) \(unit)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}
