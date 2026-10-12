import ANTuRideDomain
import SwiftUI

@MainActor
struct RangeSettingsView: View {
    @EnvironmentObject private var range: RangeService
    @EnvironmentObject private var driving: DrivingSettingsStore
    @State private var windowMinutes = DrivingSettings.defaults.rangeWindowMinutes
    @State private var refreshSeconds = DrivingSettings.defaults.rangeRefreshSeconds
    @State private var settingsNotice: String?
    @State private var settingsError: String?
    @State private var confirmingRestoreDefaults = false
    @State private var confirmingClear = false
    @State private var confirmationDeviceID: UUID?

    var body: some View {
        Form {
            Section {
                LabeledContent("已应用窗口", value: "\(Int(range.windowAge / 60)) 分钟")
                LabeledContent("已应用预测刷新", value: range.predictionRefreshInterval > 0
                    ? "每 \(Int(range.predictionRefreshInterval)) 秒" : "每次有效样本")
                Picker("窗口时长", selection: $windowMinutes) {
                    ForEach(DrivingSettings.rangeWindowMinutesBounds, id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                .accessibilityIdentifier("range.window")
                Picker("预测刷新", selection: $refreshSeconds) {
                    ForEach(DrivingSettings.rangeRefreshSecondsBounds, id: \.self) { seconds in
                        Text("每 \(seconds) 秒").tag(seconds)
                    }
                }
                .accessibilityIdentifier("range.refresh")
                Button("保存窗口与刷新") { saveRangeSettings() }
                    .accessibilityIdentifier("range.save.settings")
                Button("恢复窗口与刷新默认值", role: .destructive) {
                    confirmingRestoreDefaults = true
                }
                .accessibilityIdentifier("range.restoreDefaults")
                if let settingsNotice {
                    Text(settingsNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let settingsError {
                    Text(settingsError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("range.settings.error")
                }
            } header: {
                Text("窗口与刷新")
            } footer: {
                Text("窗口和刷新为全局偏好，所有设备共用；总容量自动读取当前 BMS，不需要手动设置。窗口按累计有效驾驶时长保留证据，停车不推进；数据过期、停车充电和保护状态会立即撤下续航。结果和导出在「仪表盘 → 综合续航」查看。")
            }

            Section {
                LabeledContent("BMS 总容量", value: range.nominalCapacityAh > 0
                    ? String(format: "%.1f Ah", range.nominalCapacityAh) : "--")
                    .accessibilityIdentifier("range.capacity.readout")
                if range.nominalCapacityAh <= 0 {
                    Text(range.deviceID == nil ? "未连接设备，等待 BMS 容量。" : "等待当前设备新鲜、有效的 BMS 容量。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("自动读取的设备参数")
            } footer: {
                Text("容量与剩余 Ah 来自当前 BMS；有效的 134 Ah 容量使用安卓内置能量表，其他容量使用安卓 legacy 公式。缺失、无效或过期数据不会用手填值或默认值替代。")
            }

            Section {
                Text(range.deviceID?.uuidString ?? "未连接设备；连接 BMS 后自动读取容量。")
                    .font(.caption)
                    .textSelection(.enabled)
                Button("清除当前有效窗口", role: .destructive) {
                    confirmationDeviceID = range.deviceID
                    confirmingClear = true
                }
                .disabled(range.deviceID == nil)
                .accessibilityIdentifier("range.clear.window")
            } footer: {
                Text("清除仅影响本设备有效驾驶窗口，之后等待新的 BMS/GPS 样本；不修改 BMS 容量、不删除其他设备证据、行程记录或已导出文件。")
            }
        }
        .navigationTitle("综合续航设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reloadRangeSettings()
        }
        .onChange(of: range.deviceID) { _ in
            confirmingClear = false
            confirmationDeviceID = nil
        }
        .onChange(of: driving.settings) { _ in
            reloadRangeSettings()
        }
        .confirmationDialog("恢复续航窗口与刷新默认值？", isPresented: $confirmingRestoreDefaults, titleVisibility: .visible) {
            Button("恢复并保存默认值", role: .destructive) {
                windowMinutes = DrivingSettings.defaults.rangeWindowMinutes
                refreshSeconds = DrivingSettings.defaults.rangeRefreshSeconds
                saveRangeSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复为 15 分钟窗口和 10 秒刷新，不改变驾驶与显示偏好、任何设备容量、行程或日志。应用较短窗口时，超出窗口的有效区间会被移除。")
        }
        .confirmationDialog("清除当前设备续航窗口？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除窗口", role: .destructive) {
                guard let id = confirmationDeviceID, id == range.deviceID else { return }
                range.clearWindow()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除当前有效行驶区间并重新等待 BMS/GPS；窗口/刷新设置保留，不修改 BMS 总容量。")
        }
    }

    private func reloadRangeSettings() {
        let safe = driving.settings.normalized()
        windowMinutes = safe.rangeWindowMinutes
        refreshSeconds = safe.rangeRefreshSeconds
    }

    private func saveRangeSettings() {
        settingsNotice = nil
        settingsError = nil
        do {
            try driving.saveRangePreferences(windowMinutes: windowMinutes, refreshSeconds: refreshSeconds)
            // RootView 也会消费同一个 Published 快照；这里立即应用，避免页面返回前显示旧配置。
            range.applyDrivingSettings(driving.settings)
            settingsNotice = "已保存到本机并应用到续航服务。"
        } catch {
            settingsError = "保存失败：\(error.localizedDescription)"
        }
    }

}
