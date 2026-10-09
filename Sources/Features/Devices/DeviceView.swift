import SwiftUI

/// 设备扫描与连接页：扫描结果按 RSSI 排序，用户点击选择后连接。
struct DeviceView: View {
    @EnvironmentObject private var bms: BmsBluetoothService

    var body: some View {
        NavigationStack {
            Group {
                if bms.state == .poweredOff {
                    PlaceholderView(title: "蓝牙未开启", message: "请在控制中心打开蓝牙后重新扫描")
                } else {
                    deviceList
                }
            }
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    scanButton
                }
            }
        }
    }

    private var scanButton: some View {
        Button {
            if bms.state == .scanning {
                bms.stopScan()
            } else {
                bms.startScan()
            }
        } label: {
            if bms.state == .scanning {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("停止")
                }
            } else {
                Label("扫描", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .disabled(bms.state == .poweredOff)
    }

    private var deviceList: some View {
        List {
            Section {
                sessionRow
            }

            Section {
                Toggle(isOn: keywordFilterBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按设备名过滤")
                        Text("仅显示 ANT BMS（ant）与 APT 控制器（apt）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(bms.isKeywordFilterEnabled
                     ? "关闭后将列出附近全部蓝牙设备，用于排查名称不含 ant / apt 的设备。"
                     : "当前列出附近全部蓝牙设备；打开后仅保留名称含 ant / apt 的设备，以及广播 FFE0 服务的设备。")
            }

            Section("附近设备") {
                if bms.discoveredDevices.isEmpty {
                    Text(bms.state == .scanning ? "正在扫描…" : "暂未发现设备，点击右上角扫描")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bms.discoveredDevices) { device in
                        Button {
                            bms.connect(to: device.id)
                        } label: {
                            deviceRow(device)
                        }
                    }
                }
            }

            if let error = bms.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.warning)
                }
            }
        }
    }

    @ViewBuilder private var sessionRow: some View {
        HStack {
            Image(systemName: stateSymbol).foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateText).font(.subheadline.weight(.medium))
                if let name = bms.connectedDeviceName, isSessionActive {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSessionActive {
                Button(role: .destructive) {
                    bms.disconnect()
                } label: {
                    Text("断开")
                }
            }
        }
    }

    private var keywordFilterBinding: Binding<Bool> {
        Binding(
            get: { bms.isKeywordFilterEnabled },
            set: { bms.setKeywordFilterEnabled($0) }
        )
    }

    private func deviceRow(_ device: BmsBluetoothService.DiscoveredDevice) -> some View {
        HStack {
            Image(systemName: "memorychip")
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .foregroundStyle(.primary)
                Text("RSSI \(device.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if bms.connectedDeviceName == device.name, isSessionActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
            }
        }
    }

    private var isSessionActive: Bool {
        switch bms.state {
        case .connecting, .discovering, .ready, .reconnecting:
            return true
        default:
            return false
        }
    }

    private var stateText: String {
        switch bms.state {
        case .idle: return "就绪，等待扫描"
        case .poweredOff: return "蓝牙未开启"
        case .scanning: return "正在扫描…"
        case .connecting: return "正在连接…"
        case .discovering: return "正在发现服务…"
        case .ready: return "已连接，数据实时"
        case .reconnecting: return "连接中断，正在重连…"
        case .disconnected: return "未连接"
        }
    }

    private var stateSymbol: String {
        switch bms.state {
        case .ready: return "checkmark.circle.fill"
        case .scanning, .connecting, .discovering, .reconnecting: return "arrow.triangle.2.circlepath"
        case .poweredOff: return "bluetooth.slash"
        case .idle, .disconnected: return "circle.dashed"
        }
    }

    private var stateColor: Color {
        switch bms.state {
        case .ready: return AppTheme.success
        case .scanning, .connecting, .discovering, .reconnecting: return AppTheme.accent
        case .poweredOff: return .secondary
        case .idle, .disconnected: return AppTheme.warning
        }
    }
}
