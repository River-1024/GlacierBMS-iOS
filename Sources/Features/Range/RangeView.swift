import ANTuRideDomain
import SwiftUI

@MainActor
struct RangeView: View {
    @EnvironmentObject private var range: RangeService

    private var windowMinutes: Int {
        max(1, Int(range.windowAge / 60))
    }

    private var refreshDescription: String {
        range.predictionRefreshInterval > 0
            ? "每 \(Int(range.predictionRefreshInterval)) 秒"
            : "每次有效样本"
    }

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
                LabeledContent("窗口平均速度", value: range.averageSpeedKmh
                    .map { String(format: "%.1f km/h", $0) } ?? "--")
                    .accessibilityIdentifier("range.average.speed")
                LabeledContent("参考电耗", value: range.referenceKmPerAh
                    .map { String(format: "%.2f km/Ah", $0) } ?? "--")
                    .accessibilityIdentifier("range.reference.consumption")
                LabeledContent("有效窗口时长", value: "累计 \(windowMinutes) 分钟")
                LabeledContent("预测刷新", value: refreshDescription)
                if range.validIntervalCount > 0 {
                    LabeledContent("有效窗口", value: String(format: "%.0f m / %.2f Wh / %d 段",
                        range.accumulatedDistanceMeters, range.accumulatedNetWh, range.validIntervalCount))
                    LabeledContent("窗口净容量变化", value: String(format: "%.4f Ah", range.accumulatedNetAh))
                    LabeledContent("窗口放电 / 回收", value: String(format: "%.2f / %.2f Wh",
                        range.accumulatedDischargeWh, range.accumulatedRegenerationWh))
                    LabeledContent("已积累驾驶时长", value: String(format: "%.0f 秒", range.effectiveDuration))
                } else {
                    Label("尚无有效行驶窗口", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("BMS 总容量", value: range.nominalCapacityAh > 0
                    ? String(format: "%.1f Ah", range.nominalCapacityAh) : "--")
                Text(range.deviceID?.uuidString ?? "未绑定稳定设备 ID；不能以设备名称隔离电池设置。")
                    .font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text("当前设备")
            } footer: {
                Text("修改窗口、刷新或清除驾驶窗口，请前往「设置 → 综合续航设置」。本页仅查看结果与导出。")
            }
            Section {
                Button("生成 JSON") { generateJSON() }
                    .accessibilityIdentifier("range.export.json")
                Button("生成 CSV") { generateCSV() }
                    .accessibilityIdentifier("range.export.csv")
                if let url = range.lastExportURL {
                    ShareLink(item: url) { Label("分享导出文件", systemImage: "square.and.arrow.up") }
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let error = range.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("range.export.error")
                }
            } header: {
                Text("本地导出")
            } footer: {
                Text("导出当前状态与有效窗口；没有有效窗口时也会导出明确的空状态，不包含原始 GPS 坐标，不会上传。")
            }
            Section("估计边界") {
                Text("续航使用最近累计 \(windowMinutes) 分钟的有效驾驶区间和安卓内置能量曲线（\(AndroidEnergyCurve.version)）。区间平均速度须达到 3 km/h；至少积累 30 秒、200 米、5 Wh 放电和 5 Wh 净能耗。移动回收从放电中扣除；停车不推进窗口，缺口与坏区间不补算，也不淘汰旧驾驶证据。")
                Text("窗口平均速度按有效位移与区间时长计算；参考电耗按相同区间 BMS 剩余 Ah 差值计算 km/Ah，不使用总行程，也不以 Wh/电压推算 Ah。净 Ah 不为正时不显示参考电耗。")
                Text("总容量自动读取当前 BMS；驾驶证据按稳定外设 UUID 本机保存，恢复时校验 BMS 容量，容量变化会清除旧窗口；重连仍需新的 BMS/GPS，遥测或最后驾驶证据超过 30 秒不显示预测。页面不会执行电池学习或校准，也不会导入手机私有学习数据库；状态不满足条件时不显示续航数值。")
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
