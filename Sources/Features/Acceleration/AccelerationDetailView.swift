import ANTuRideDomain
import SwiftUI

@MainActor
struct AccelerationDetailView: View {
    let record: AccelerationRecord
    @EnvironmentObject private var acceleration: AccelerationService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var showingExport = false
    @State private var exportURL: URL?
    @State private var actionError: String?

    private var isSaved: Bool { acceleration.records.contains { $0.id == record.id } }
    private var result: AccelerationChannelResult? { record.result(for: .rpm) }

    var body: some View {
        List {
            Section("记录") {
                Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                accelerationValueRow("结果状态", accelerationPhaseText(record.phase))
                accelerationValueRow("目标", accelerationNumber(record.config.targetSpeedKmh, unit: "km/h"))
                accelerationValueRow("RPM 系数", record.config.rpmKmhPerUnit.map { String($0) } ?? "未配置")
                accelerationValueRow("forwardSign", "\(record.config.rpmForwardSign)")
                accelerationValueRow("算法", record.config.algorithmVersion)
                accelerationValueRow("保存", isSaved ? "已保存 JSON" : "未保存；退出进程会丢失")
                if let reason = record.endReason { Text(reason).font(.footnote) }
                if !isSaved, acceleration.pendingSaveRecord?.id == record.id {
                    Button("重试保存") { acceleration.retryPendingSave() }
                }
                Button("分享完整 JSON") { share() }
                    .accessibilityIdentifier("acceleration-share")
                Button("删除此记录", role: .destructive) { confirmingDeletion = true }
                    .disabled(!isSaved || acceleration.pendingSaveRecord?.id == record.id)
                    .accessibilityIdentifier("acceleration-delete")
                if let actionError { Text(actionError).foregroundStyle(AppTheme.danger) }
                if let error = acceleration.historyError { Text(error).foregroundStyle(AppTheme.danger) }
            }
            Section("RPM 分段结果 · 接收时序估计") {
                if let result {
                    accelerationValueRow("RPM 状态", accelerationChannelText(result.state))
                    if result.splits.isEmpty { Text("没有已确认的目标分段；不以占位数据补齐结果。").foregroundStyle(.secondary) }
                    ForEach(result.splits.indices, id: \.self) { index in
                        let split = result.splits[index]
                        let previousTarget = index == 0 ? 0 : result.splits[index - 1].targetSpeedKmh
                        VStack(alignment: .leading, spacing: 4) {
                            Text("0–\(accelerationNumber(split.targetSpeedKmh, unit: "km/h"))")
                                .font(.headline)
                            Text("累计 \(accelerationNumber(split.cumulativeSeconds, unit: "s")) · \(accelerationNumber(previousTarget, unit: ""))–\(accelerationNumber(split.targetSpeedKmh, unit: "km/h")) 分段 \(accelerationNumber(split.segmentSeconds, unit: "s"))")
                                .font(.subheadline)
                            Text("RPM 换算累计距离 \(accelerationNumber(split.distanceMeters, unit: "m"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let reason = result.reason { Text(reason).foregroundStyle(AppTheme.warning) }
                    if let warning = result.lastQualityWarning { Text(warning).font(.footnote) }
                }
            }
            Section("采样质量") {
                accelerationValueRow("速度 / 电流样本", "\(record.speedSamples.count) / \(record.currentSamples.count)")
                if let result {
                    accelerationValueRow("有效接收频率", accelerationNumber(result.effectiveHz, unit: "Hz"))
                    accelerationValueRow("最大接收间隙", accelerationNumber(result.maxGapMs, unit: "ms"))
                    accelerationValueRow("拒绝样本", "\(result.rejectedSampleCount)")
                    accelerationValueRow("起步插值区间", accelerationNumber(result.startUncertaintyMs, unit: "ms"))
                }
                Text("起步插值区间只反映相邻接收样本间隔，不涵盖未知的蓝牙传输延迟，不是硬件精度或总体误差上限。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("条件 / 计时说明") {
                Text("手机单调接收时间，非控制器硬件测量时刻；仅 RPM × 系数 × forwardSign。系数没有经过本应用实车校准。")
                    .font(.footnote).foregroundStyle(AppTheme.warning)
                ForEach(record.conditions.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.caption).foregroundStyle(.secondary)
                        Text(record.conditions[key] ?? "")
                    }
                }
                Text("分享 JSON 包含完整接收时间、原始 RPM、电流、速度样本及所有已确认分段。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("加速记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除此加速记录？本机 JSON 删除后无法恢复。", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) {
                acceleration.delete(record)
                if !isSaved { dismiss() }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showingExport, onDismiss: {
            exportURL = nil
            acceleration.clearExportURL()
        }) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
    }

    private func share() {
        do {
            exportURL = try acceleration.exportJSON(record)
            actionError = nil
            showingExport = true
        } catch { actionError = "分享失败：\(error.localizedDescription)" }
    }
}

func accelerationValueRow(_ title: String, _ value: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        Text(value).monospacedDigit().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
}

func accelerationNumber(_ value: Double?, unit: String) -> String {
    guard let value, value.isFinite else { return "--" }
    return String(format: "%.2f%@", value, unit.isEmpty ? "" : " \(unit)")
}

func accelerationPhaseText(_ phase: AccelerationPhase) -> String {
    switch phase {
    case .armed: return "等待静止 / 起步"
    case .running: return "计时中"
    case .completed: return "已达到目标"
    case .partial: return "未完成 / 部分分段"
    case .interrupted: return "已中止"
    }
}

func accelerationChannelText(_ state: AccelerationChannelState) -> String {
    switch state {
    case .waitingStill: return "等待连续静止 2 秒"
    case .ready: return "静止已确认，等待起步"
    case .running: return "运行中"
    case .reached: return "达到目标"
    case .invalid: return "失效"
    case .unavailable: return "不可用"
    }
}
