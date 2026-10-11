import ANTuRideDomain
import SwiftUI

/// 控制器 Tab 的内容；由 Root 包装 NavigationStack。
/// 全局轮询仍由 App/Root 管理，本页不改变共享 BLE 会话。
struct ControllerView: View {
    @EnvironmentObject private var controller: ControllerBluetoothService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let telemetry = currentTelemetry(at: context.date)
            List {
                Section("控制器连接 · 只读") {
                    row("连接状态", controller.state.text)
                        .accessibilityIdentifier("controller.connection.status")
                    row("设备名称", controller.connectedDeviceName ?? "--")
                    Label(telemetry == nil ? "实时数据不可用" : "数据有效 · 1 秒内更新",
                          systemImage: telemetry == nil ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(telemetry == nil ? AppTheme.warning : AppTheme.success)
                    if telemetry == nil {
                        Text(unavailableMessage(at: context.date))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("controller.noData")
                    }
                }
                Section("基础电气") {
                    row("控制器电压", number(telemetry?.controllerVoltageV, unit: "V"))
                    row("母线电流", number(telemetry?.busCurrentA, unit: "A"))
                    row("相线峰值电流", number(telemetry?.phasePeakCurrentA, unit: "A"))
                    row("转速", telemetry.map { "\($0.rpm) RPM" } ?? "--")
                    row("车速", "--")
                }
                Section("温度与输入") {
                    row("控制器温度", telemetry.map { "\($0.controllerTemperatureC) ℃" } ?? "--")
                    row("电机温度", telemetry.map { "\($0.motorTemperatureC) ℃" } ?? "--")
                    row("转把电压", number(telemetry?.throttleVoltageV, unit: "V"))
                    row("线性刹车电压", number(telemetry?.linearBrakeVoltageV, unit: "V"))
                }
                Section("运行状态与故障") {
                    row("运行状态", telemetry?.runStateText ?? "--")
                    row("档位", telemetry.map { String($0.gear, radix: 16) } ?? "--")
                    row("控制器状态位", telemetry.map { String($0.controllerStateBits) } ?? "--")
                    row("当前故障", telemetry?.faultSummary ?? "--")
                    row("当前故障位", telemetry.map { String($0.faultBits) } ?? "--")
                    row("端口状态位", telemetry.map { String($0.portStatusBits) } ?? "--")
                    row("历史故障位", telemetry.map { String($0.historyFaultBits) } ?? "--")
                }
                Section("Iq / Id 与弱磁") {
                    row("给定 Iq", number(telemetry?.givenIqA, unit: "A"))
                    row("反馈 Iq", number(telemetry?.feedbackIqA, unit: "A"))
                    row("给定 Id", number(telemetry?.givenIdA, unit: "A"))
                    row("弱磁电流", number(telemetry?.fieldWeakeningA, unit: "A"))
                }
                Section {
                    row("通知 / 整帧", "\(controller.notificationCount) / \(controller.frameCount)")
                    row("待拼接字节", "\(controller.pendingByteCount)")
                    LabeledContent("最后有效帧时间") {
                        if let date = controller.lastValidAt {
                            Text(date, format: .dateTime.year().month().day().hour().minute().second())
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("--")
                        }
                    }
                    if let error = controller.lastError {
                        Text(error).foregroundStyle(AppTheme.danger)
                    }
                } header: {
                    Text("通讯诊断")
                } footer: {
                    Text("50 ms 查询节奏，单请求在途。断开、查询暂停或超过 1 秒未更新时，实时值显示 --。通知与整帧计数仅作诊断，不代表数据仍有效。转速不等于车速，当前没有控制器车速来源。")
                }
                Section {
                    NavigationLink {
                        ControllerHistoryView()
                    } label: {
                        Label("记录与历史", systemImage: "clock.arrow.circlepath")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("controller.history")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("控制器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func currentTelemetry(at now: Date) -> MotorControllerTelemetry? {
        guard controller.state == .ready,
              let date = controller.lastValidAt,
              now.timeIntervalSince(date) >= 0,
              now.timeIntervalSince(date) < ControllerBluetoothService.responseTimeout else { return nil }
        return controller.latestTelemetry
    }

    private func unavailableMessage(at now: Date) -> String {
        guard controller.state == .ready else { return "请前往设置 → 蓝牙设备" }
        if let date = controller.lastValidAt,
           now.timeIntervalSince(date) >= ControllerBluetoothService.responseTimeout {
            return "超过 1 秒未收到有效数据，实时值已隐藏。请前往设置 → 蓝牙设备检查连接。"
        }
        return "暂无控制器数据，等待有效帧。请前往设置 → 蓝牙设备检查连接。"
    }

    private func number(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), value, unit)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}
