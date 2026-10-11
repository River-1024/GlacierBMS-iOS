import ANTuRideDomain
import SwiftUI

/// 唯一扫描/连接管理入口；页面只订阅 App 持有的两个独立 BLE 服务。
@MainActor
struct BluetoothDevicesView: View {
    @EnvironmentObject private var bms: BmsBluetoothService
    @EnvironmentObject private var controller: ControllerBluetoothService
    @EnvironmentObject private var driving: DrivingSettingsStore
    @State private var preferenceError: String?
    @State private var forgetTarget: ForgetTarget?
    @State private var confirmingForget = false

    private struct ForgetTarget {
        let role: BluetoothDeviceRole
        let id: UUID
        let name: String
    }

    var body: some View {
        List {
            Section {
                Text("电池和控制器分别记忆、分别连接；名称仅筛选候选，连接后仍校验协议。扫描不会自动选择信号最强或同名设备。")
                    .foregroundStyle(.secondary)
            }
            batterySection
            controllerSection
            if let preferenceError {
                Section("设置未保存") {
                    Label(preferenceError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.warning)
                }
            }
        }
        .navigationTitle("蓝牙设备")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("忘记\(forgetTarget?.name ?? "设备")？", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("忘记设备", role: .destructive) { forgetConfirmedDevice() }
            Button("取消", role: .cancel) { forgetTarget = nil }
        } message: {
            Text("将断开并删除此角色的连接记忆，下次打开 App 不再自动连接。此操作无法撤销，但可重新扫描连接；不会删除历史、行程、电池容量或另一类设备记忆。")
        }
        .onDisappear {
            bms.stopManualScan()
            controller.stopManualScan()
        }
    }

    private var batterySection: some View {
        Section {
            LabeledContent("连接状态", value: batteryStateText)
                .accessibilityIdentifier("bluetooth.battery.status")
            if let name = bms.connectedDeviceName, bms.isConnectionActive {
                LabeledContent("当前电池", value: name)
            }
            rememberedRow(name: bms.rememberedDeviceName, id: bms.rememberedDeviceID)
            Toggle("自动连接上次电池", isOn: batteryAutoConnect)
                .accessibilityIdentifier("bluetooth.battery.autoConnect")
            Toggle("按名称过滤（ant）", isOn: Binding(
                get: { bms.isKeywordFilterEnabled }, set: { bms.setKeywordFilterEnabled($0) }))
                .accessibilityIdentifier("bluetooth.battery.filter")
            actionButton(bms.state == .scanning ? "停止扫描电池" : "扫描电池", id: "bluetooth.battery.scan") {
                if bms.state == .scanning { bms.stopScan() } else { bms.startScan() }
            }
            .disabled(bms.isConnectionActive || bms.state == .poweredOff)
            if bms.isConnectionActive {
                actionButton("断开电池", id: "bluetooth.battery.disconnect", role: .destructive) { bms.disconnect() }
            } else if bms.rememberedDeviceID != nil {
                actionButton("重试连接上次电池", id: "bluetooth.battery.retry") {
                    bms.reconnectRememberedDevice()
                }
                .disabled(bms.state == .poweredOff)
            }
            if let id = bms.rememberedDeviceID {
                actionButton("忘记电池", id: "bluetooth.battery.forget", role: .destructive) {
                    forgetTarget = ForgetTarget(role: .battery, id: id, name: bms.rememberedDeviceName ?? "上次电池")
                    confirmingForget = true
                }
            }
            if bms.state == .scanning {
                ProgressView("正在搜索电池…")
                if bms.discoveredDevices.isEmpty {
                    Text("暂未发现匹配设备；检查电池是否开机，或关闭本区域名称过滤进行排障。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(bms.discoveredDevices) { device in
                Button { bms.connect(to: device.id) } label: {
                    BluetoothCandidateRow(name: device.name, id: device.id, rssi: device.rssi)
                }
                .frame(minHeight: 44)
                .disabled(bms.isConnectionActive)
                .accessibilityLabel("连接电池 \(device.name)")
            }
            if let error = bms.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
            }
        } header: { Text("电池连接") } footer: {
            Text("默认只列出名称包含 ant 的设备（不区分大小写）；关闭过滤仅用于排障。启动和返回前台各尝试一次上次 UUID，不保证设备可达。主动断开后本次运行不抢连，下次打开仍保留记忆。")
        }
    }

    private var controllerSection: some View {
        Section {
            LabeledContent("连接状态", value: controller.state.text)
                .accessibilityIdentifier("bluetooth.controller.status")
            if let name = controller.connectedDeviceName, controller.isConnectionActive {
                LabeledContent("当前控制器", value: name)
            }
            rememberedRow(name: controller.rememberedDeviceName, id: controller.rememberedDeviceID)
            Toggle("自动连接上次控制器", isOn: controllerAutoConnect)
                .accessibilityIdentifier("bluetooth.controller.autoConnect")
            Toggle("按名称过滤（apt）", isOn: Binding(
                get: { controller.isKeywordFilterEnabled }, set: { controller.setKeywordFilterEnabled($0) }))
                .accessibilityIdentifier("bluetooth.controller.filter")
            actionButton(controller.state == .scanning ? "停止扫描控制器" : "扫描控制器", id: "bluetooth.controller.scan") {
                if controller.state == .scanning { controller.stopScan() } else { controller.startScan() }
            }
            .disabled(controller.isConnectionActive || controller.state == .unavailable)
            if controller.isConnectionActive {
                actionButton("断开控制器", id: "bluetooth.controller.disconnect", role: .destructive) { controller.disconnect() }
            } else if controller.rememberedDeviceID != nil {
                actionButton("重试连接上次控制器", id: "bluetooth.controller.retry") {
                    controller.reconnectRememberedDevice()
                }
                .disabled(controller.state == .unavailable)
            }
            if let id = controller.rememberedDeviceID {
                actionButton("忘记控制器", id: "bluetooth.controller.forget", role: .destructive) {
                    forgetTarget = ForgetTarget(role: .controller, id: id, name: controller.rememberedDeviceName ?? "上次控制器")
                    confirmingForget = true
                }
            }
            if controller.state == .scanning {
                ProgressView("正在搜索控制器…")
                if controller.discoveredDevices.isEmpty {
                    Text("暂未发现匹配设备；检查控制器是否开机，或关闭本区域名称过滤进行排障。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(controller.discoveredDevices) { device in
                Button { controller.connect(to: device.id) } label: {
                    BluetoothCandidateRow(name: device.name, id: device.id, rssi: device.rssi)
                }
                .frame(minHeight: 44)
                .disabled(controller.isConnectionActive)
                .accessibilityLabel("连接控制器 \(device.name)")
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppTheme.warning)
            }
            if controller.isRecording {
                Text("断开将停止并尝试保存当前控制器记录；保存失败时可在记录与历史页重试或导出。")
                    .foregroundStyle(AppTheme.warning)
            }
        } header: { Text("控制器连接") } footer: {
            Text("默认只列出名称包含 apt 的设备。断开/忘记只影响控制器，不影响电池；开关立即保存到本机；开启不会即时抢连，关闭会取消未完成的自动尝试，但不关闭已验证连接。记录与历史在控制器 Tab 的二级页面。")
        }
    }

    @ViewBuilder private func rememberedRow(name: String?, id: UUID?) -> some View {
        if let id {
            LabeledContent("上次成功设备", value: name ?? "已记忆设备")
            Text(id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            LabeledContent("上次成功设备", value: "尚未记忆")
        }
    }

    private func actionButton(_ title: String, id: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(title, role: role, action: action).frame(minHeight: 44).accessibilityIdentifier(id)
    }

    private var batteryAutoConnect: Binding<Bool> {
        Binding(get: { driving.settings.bmsAutoConnectEnabled }, set: { enabled in
            saveAutoConnect(battery: enabled, controller: driving.settings.controllerAutoConnectEnabled)
        })
    }

    private var controllerAutoConnect: Binding<Bool> {
        Binding(get: { driving.settings.controllerAutoConnectEnabled }, set: { enabled in
            saveAutoConnect(battery: driving.settings.bmsAutoConnectEnabled, controller: enabled)
        })
    }

    private func saveAutoConnect(battery: Bool, controller: Bool) {
        do {
            try driving.saveBluetoothPreferences(bmsEnabled: battery, controllerEnabled: controller)
            preferenceError = nil
        } catch { preferenceError = error.localizedDescription }
    }

    private func forgetConfirmedDevice() {
        guard let target = forgetTarget else { return }
        defer { forgetTarget = nil }
        let rememberedID = target.role == .battery ? bms.rememberedDeviceID : controller.rememberedDeviceID
        guard rememberedID == target.id else {
            preferenceError = "设备记忆已变化，请重新确认要忘记的设备。"
            return
        }
        if target.role == .battery { bms.forgetDevice() } else { controller.forgetDevice() }
        preferenceError = nil
    }

    private var batteryStateText: String {
        switch bms.state {
        case .idle: return "未连接"
        case .poweredOff: return "蓝牙不可用，请检查权限和蓝牙开关"
        case .scanning: return "搜索中"
        case .connecting: return "连接中"
        case .discovering: return "校验服务中"
        case .ready: return bms.latestSnapshot == nil ? "已连接，等待有效数据" : "已连接"
        case .reconnecting: return "正在尝试连接上次电池"
        case .disconnected: return "已断开"
        }
    }
}

private struct BluetoothCandidateRow: View {
    let name: String
    let id: UUID
    let rssi: Int

    var body: some View {
        VStack(alignment: .leading) {
            Text(name).foregroundStyle(.primary)
            Text("\(id.uuidString.suffix(8)) · RSSI \(rssi) dBm")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}
