import ANTuRideDomain
import SwiftUI

@MainActor
struct RangeSettingsView: View {
    @EnvironmentObject private var range: RangeService
    @EnvironmentObject private var driving: DrivingSettingsStore
    @State private var capacityText = ""
    @State private var windowMinutes = DrivingSettings.defaults.rangeWindowMinutes
    @State private var refreshSeconds = DrivingSettings.defaults.rangeRefreshSeconds
    @State private var validationError: String?
    @State private var settingsNotice: String?
    @State private var settingsError: String?
    @State private var confirmingRestoreDefaults = false
    @State private var confirmingClear = false
    @State private var confirmingReset = false
    @State private var confirmationDeviceID: UUID?
    @FocusState private var editingCapacity: Bool

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
                Text("窗口和刷新为全局偏好，所有设备共用；容量单独按设备保存。窗口保留最近的有效行驶区间，数据过期、充电和保护状态仍会立即撤下续航。结果和导出在「仪表盘 → 综合续航」查看。")
            }

            Section {
                HStack {
                    Text("额定容量")
                    TextField("尚未设置", text: $capacityText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($editingCapacity)
                        .accessibilityIdentifier("range.capacity")
                    Text("Ah").foregroundStyle(.secondary)
                }
                Button("保存本设备容量") { saveCapacity() }
                    .disabled(range.deviceID == nil)
                    .accessibilityIdentifier("range.save.capacity")
                if let error = validationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("设备参数")
            } footer: {
                Text("请填写电池真实额定容量；不会预填假定的 100 Ah。容量按稳定外设 UUID 保存，仅修改本设备。")
            }

            Section {
                Text(range.deviceID?.uuidString ?? "未连接设备；连接 BMS 后可设置本设备容量。")
                    .font(.caption)
                    .textSelection(.enabled)
                Button("清除当前有效窗口", role: .destructive) {
                    confirmationDeviceID = range.deviceID
                    confirmingClear = true
                }
                .disabled(range.deviceID == nil)
                .accessibilityIdentifier("range.clear.window")
                Button("重置本设备容量与窗口", role: .destructive) {
                    confirmationDeviceID = range.deviceID
                    confirmingReset = true
                }
                .disabled(range.deviceID == nil)
                .accessibilityIdentifier("range.reset.device")
            } footer: {
                Text("清除窗口会保留本设备容量；重置会同时删除本设备容量设置。两者都不删除其他设备设置、行程记录或已导出文件。")
            }
        }
        .navigationTitle("综合续航设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reloadCapacity()
            reloadRangeSettings()
        }
        .onChange(of: range.deviceID) { _ in
            confirmingClear = false
            confirmingReset = false
            confirmationDeviceID = nil
            editingCapacity = false
            reloadCapacity()
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
            Text("只清除当前有效行驶区间，额定容量和窗口/刷新设置保留。")
        }
        .confirmationDialog("重置本设备容量与窗口？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) {
                guard let id = confirmationDeviceID, id == range.deviceID else { return }
                editingCapacity = false
                range.reset()
                reloadCapacity()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除当前设备的额定容量设置与有效窗口，不能撤销；不恢复全局窗口/刷新，也不删除其他设备容量、行程或导出文件。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editingCapacity = false }
            }
        }
    }

    private func reloadCapacity() {
        capacityText = range.nominalCapacityAh > 0 ? range.nominalCapacityAh.formatted(.number) : ""
        validationError = nil
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

    private func saveCapacity() {
        // 与本地化显示格式一致（例如小数逗号地区），也接受普通点号输入。
        let text = capacityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = (try? Double(text, format: .number)) ?? Double(text), value.isFinite, value > 0 else {
            validationError = "请输入大于零的有效容量（Ah）"
            return
        }
        guard range.updateNominalCapacityAh(value) else {
            validationError = range.lastError
            return
        }
        editingCapacity = false
        reloadCapacity()
    }
}
