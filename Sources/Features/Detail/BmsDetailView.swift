import GlacierBMSDomain
import SwiftUI

/// BMS 详情页：单体电压、温度、MOS 与运行信息。
/// 数据过期时显式标注，不用陈旧值伪装实时。
struct BmsDetailView: View {
    @EnvironmentObject private var bms: BmsBluetoothService

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snapshot = bms.latestSnapshot
                let freshness = BmsFreshnessEvaluator().evaluate(snapshot: snapshot, now: context.date)
                ScrollView {
                    VStack(spacing: 16) {
                        freshnessCard(freshness)
                        if let snapshot, freshness.level != .noData {
                            cellSummaryCard(snapshot)
                            cellListCard(snapshot)
                            temperatureCard(snapshot)
                            mosStatusCard(snapshot)
                        } else {
                            PlaceholderView(title: "暂无 BMS 数据", message: "请在「设备」页扫描并连接 ANT BMS")
                        }
                    }
                    .padding()
                }
                .navigationTitle("详情")
            }
        }
    }

    private func freshnessCard(_ freshness: BmsDataFreshness) -> some View {
        HStack {
            Label(freshnessText(freshness), systemImage: freshnessSymbol(freshness))
                .foregroundStyle(freshnessColor(freshness))
                .font(.subheadline.weight(.medium))
            Spacer()
            if let name = bms.connectedDeviceName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .glassCard(cornerRadius: 16)
    }

    private func cellSummaryCard(_ snapshot: BmsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("单体电压").font(.headline)
            HStack {
                summaryItem("最高", snapshot.maxCellVoltageMillivolts)
                summaryItem("最低", snapshot.minCellVoltageMillivolts)
                summaryItem("压差", snapshot.voltageDiffMillivolts)
            }
            HStack {
                summaryItem("总电压 mV", nil, valueText: String(Int(snapshot.totalVoltage * 1000)))
                summaryItem("SOH", snapshot.soh.map { "\($0)%" })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard()
    }

    private func summaryItem(_ title: String, _ millivolts: Int?, valueText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(valueText ?? (millivolts.map { BmsFormatters.millivolts($0) } ?? "--"))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cellListCard(_ snapshot: BmsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("单体列表").font(.headline)
            let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(snapshot.cellVoltagesMillivolts.enumerated()), id: \.offset) { index, millivolts in
                    VStack(spacing: 2) {
                        Text("#\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        Text("\(millivolts)").font(.caption.weight(.medium)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard()
    }

    private func temperatureCard(_ snapshot: BmsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("温度").font(.headline)
            if snapshot.temperatures.isEmpty {
                Text("BMS 未上报温度探头").font(.subheadline).foregroundStyle(.secondary)
            } else {
                let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(snapshot.temperatures.enumerated()), id: \.offset) { index, celsius in
                        VStack(spacing: 2) {
                            Text("T\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                            Text("\(celsius)°C").font(.caption.weight(.medium)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Text("MOS \(snapshot.mosTemperature)°C")
                Text("均衡 \(snapshot.balancerTemperature)°C")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard()
    }

    private func mosStatusCard(_ snapshot: BmsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("状态与运行").font(.headline)
            HStack {
                mosChip("充电 MOS", on: snapshot.chargeMOSOn)
                mosChip("放电 MOS", on: snapshot.dischargeMOSOn)
            }
            HStack {
                Text("BMS 状态").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.statusText).font(.subheadline.weight(.medium))
            }
            if let runtime = BmsFormatters.runtime(snapshot.runtimeSeconds) {
                HStack {
                    Text("运行时长").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(runtime).font(.subheadline.weight(.medium)).monospacedDigit()
                }
            }
            if let balance = snapshot.balanceStatus {
                HStack {
                    Text("均衡状态码").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(balance)").font(.subheadline.weight(.medium)).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassCard()
    }

    private func mosChip(_ title: String, on: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on == true ? AppTheme.success : (on == false ? Color.secondary : AppTheme.warning))
                .frame(width: 8, height: 8)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func freshnessText(_ freshness: BmsDataFreshness) -> String {
        switch freshness.level {
        case .noData: return "等待数据"
        case .fresh: return "实时 · \(Int(freshness.ageSeconds ?? 0))s 内"
        case .stale: return "数据过期 \(Int(freshness.ageSeconds ?? 0))s"
        }
    }

    private func freshnessSymbol(_ freshness: BmsDataFreshness) -> String {
        switch freshness.level {
        case .noData: return "hourglass"
        case .fresh: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        }
    }

    private func freshnessColor(_ freshness: BmsDataFreshness) -> Color {
        switch freshness.level {
        case .noData: return .secondary
        case .fresh: return AppTheme.success
        case .stale: return AppTheme.warning
        }
    }
}
