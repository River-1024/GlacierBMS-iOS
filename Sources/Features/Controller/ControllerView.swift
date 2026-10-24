import ANTuRideDomain
import SwiftUI

/// 控制器 Tab 的内容；由 Root 包装 NavigationStack。
/// 全局轮询仍由 App/Root 管理，本页不改变共享 BLE 会话。
@MainActor
struct ControllerView: View {
    @EnvironmentObject private var controller: ControllerBluetoothService
    @EnvironmentObject private var acceleration: AccelerationService
    @StateObject private var layout = ParameterLayoutStore(page: .controller)
    @State private var showingHistory = false
    @State private var showingAcceleration = false

    var body: some View {
        ParameterCardPage(store: layout, leadingContent: AnyView(connectionContent),
                          trailingContent: AnyView(toolEntries)) { placement in
            AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
                let telemetry = currentTelemetry(at: context.date)
                let readout = DeviceParameterReadout.read(controller: telemetry, metricID: placement.id,
                    notificationCount: controller.notificationCount, frameCount: controller.frameCount,
                    pendingByteCount: controller.pendingByteCount)
                AppMetricCard(title: readout.title, value: readout.value, unit: readout.unit,
                              detail: readout.detail,
                              color: placement.id == "controller_fault" && telemetry.map { $0.faultBits != 0 } == true
                                  ? AppTheme.danger : .primary,
                              prominent: placement.size == .hero)
            })
        }
        .navigationTitle("控制器")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingHistory) { ControllerHistoryView() }
        .navigationDestination(isPresented: $showingAcceleration) { AccelerationView() }
    }

    private var connectionContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let telemetry = currentTelemetry(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                Text("控制器连接 · 只读").font(.headline)
                row("连接状态", controller.state.text)
                    .accessibilityIdentifier("controller.connection.status")
                row("设备名称", deviceName)
                row("运行状态", telemetry?.runStateText ?? "--")
                Label(telemetry == nil ? "实时数据不可用" : "数据有效 · 1 秒内更新",
                      systemImage: telemetry == nil ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(telemetry == nil ? AppTheme.warning : AppTheme.success)
                if telemetry == nil {
                    Text(unavailableMessage(at: context.date))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("controller.noData")
                }
                LabeledContent("最后有效帧时间（仅供排查）") {
                    if let date = controller.lastValidAt {
                        Text(date, format: .dateTime.year().month().day().hour().minute().second())
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("--")
                    }
                }
                // 固定在编辑网格之外，隐藏/收起故障卡不能隐藏安全提示。
                if let lastTelemetry = controller.latestTelemetry, lastTelemetry.faultBits != 0 {
                    Label(telemetry == nil ? "最后有效帧故障（非实时）：\(lastTelemetry.faultSummary)"
                          : "当前故障：\(lastTelemetry.faultSummary)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.danger)
                        .accessibilityIdentifier("controller.fault.warning")
                }
                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.danger)
                }
                Text("50 ms 查询节奏，单请求在途。断开、查询暂停或超过 1 秒未更新时，实时值显示 --。监测计数和最后有效帧时间仅供诊断，不代表数据仍有效。转速不等于车速，当前没有控制器车速来源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// 与"记录与历史"并列的固定工具入口；网格编辑不能移动或隐藏它们。
    private var toolEntries: some View {
        VStack(spacing: 8) {
            accelerationButton
            historyButton
        }
    }

    /// 与设置页入口指向同一测试页，参数仍只在测试页编辑。
    private var accelerationButton: some View {
        Button {
            showingAcceleration = true
        } label: {
            HStack(spacing: 8) {
                Label("加速测试", systemImage: "speedometer")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                if acceleration.isActive {
                    Label("测试进行中", systemImage: "record.circle")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.warning)
                }
            }
        }
        .accessibilityLabel(acceleration.isActive ? "加速测试，测试进行中" : "加速测试")
        .accessibilityIdentifier("controller.acceleration")
    }

    private var historyButton: some View {
        Button {
            showingHistory = true
        } label: {
            Label("记录与历史", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("controller.history")
    }

    private var deviceName: String {
        guard let name = controller.connectedDeviceName, !name.isEmpty else { return "--" }
        return name
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

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}
