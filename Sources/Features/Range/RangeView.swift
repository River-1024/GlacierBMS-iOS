import ANTuRideDomain
import SwiftUI

@MainActor
struct RangeView: View {
    @EnvironmentObject private var range: RangeService

    var body: some View {
        List {
            Section("当前续航") {
                LabeledContent("状态", value: range.status.localizedName)
                Text(range.reasonText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("range.reason")
                LabeledContent("预计续航", value: range.prediction?.predictedRangeKm
                    .map { String(format: "%.1f km", $0) } ?? "--")
                    .accessibilityIdentifier("range.prediction")
                LabeledContent("窗口能耗", value: range.effectiveWhPerKm
                    .map { String(format: "%.1f Wh/km", $0) } ?? "--")
                if range.validIntervalCount > 0 {
                    LabeledContent("有效窗口", value: String(format: "%.0f m / %.2f Wh / %d 段",
                        range.accumulatedDistanceMeters, range.accumulatedNetWh, range.validIntervalCount))
                } else {
                    Label("尚无有效行驶窗口", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink {
                    RangeSettingsView()
                } label: {
                    Label("额定容量与重置", systemImage: "battery.100")
                }
            } header: {
                Text("当前设备")
            } footer: {
                Text(range.deviceID?.uuidString ?? "未绑定稳定设备 ID；不能以设备名称隔离电池设置。")
            }
            Section {
                Button("生成 JSON") { generateJSON() }
                Button("生成 CSV") { generateCSV() }
                if let url = range.lastExportURL {
                    ShareLink(item: url) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                if let error = range.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("本地导出")
            } footer: {
                Text("导出当前状态与有效窗口，不包含原始 GPS 坐标，不会上传。")
            }
            Section("估计边界") {
                Text("使用最近 5 分钟有效行驶区间估算能耗，剩余能量复用安卓内置曲线 d1-ah-seed-20260909-v1。134 Ah 源电池使用原始分段表，其他容量使用安卓后备公式；不做电池学习或校准，也未导入手机私有学习数据。")
                Text("未绑定设备、定位未启动、数据过期、停车、充电/负功率或保护状态时不显示续航数值；不补算数据缺口。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("综合续航")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func generateJSON() {
        do { _ = try range.exportJSON() }
        catch { /* 错误由服务发布，保持在页面可见。 */ }
    }
    private func generateCSV() {
        do { _ = try range.exportCSV() }
        catch { /* 错误由服务发布，保持在页面可见。 */ }
    }
}
