import SwiftUI

/// App 唯一设置总入口；配置编辑与实时结果/测试工具分组，避免重复续航编辑器。
@MainActor
struct SettingsView: View {
    @EnvironmentObject private var driving: DrivingSettingsStore
    @State private var recordLevel: LogLevel = AppLog.shared.minimumLevel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { BluetoothDevicesView() } label: {
                        Label("蓝牙设备", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("settings.bluetooth")
                } header: { Text("连接管理") } footer: {
                    Text("电池与控制器分别搜索、连接、断开和记忆；自动连接策略在蓝牙设备中设置。")
                }

                Section {
                    NavigationLink { DrivingSettingsView(store: driving) } label: {
                        Label("驾驶与显示设置", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("settings.driving")
                    NavigationLink { HomeParameterEditorView() } label: {
                        Label("首页参数", systemImage: "rectangle.3.group")
                    }
                    .accessibilityIdentifier("settings.home")
                } header: {
                    Text("驾驶与显示")
                } footer: {
                    Text("主题、字号、功率图、颜色阈值、BMS 查询周期在驾驶设置中修改；首页固定使用槽位布局，槽位指标独立保存，未保存的草稿不会生效。")
                }

                Section {
                    NavigationLink { RangeSettingsView() } label: {
                        Label("综合续航设置", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    .accessibilityIdentifier("settings.range")
                } header: {
                    Text("综合续航")
                } footer: {
                    Text("窗口与刷新为所有设备共用的偏好，总容量自动读取当前 BMS，无需再次填写。续航结果与 JSON/CSV 导出从「仪表盘 → 综合续航」查看。")
                }

                Section {
                    NavigationLink { AccelerationView() } label: {
                        Label("RPM 加速测试与历史", systemImage: "speedometer")
                    }
                    .accessibilityIdentifier("settings.acceleration")
                    NavigationLink { ControllerHistoryView() } label: {
                        Label("控制器记录与历史", systemImage: "engine.combustion")
                    }
                    .accessibilityIdentifier("settings.controller")
                } header: {
                    Text("工具与记录")
                } footer: {
                    Text("加速测试只使用控制器 RPM；测试参数在测试页设置，不写入 BMS 或控制器硬件配置。")
                }

                Section {
                    NavigationLink { LogViewerView() } label: {
                        Label("运行日志", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("settings.logs")
                    Picker("记录等级", selection: $recordLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text("\(level.tag) — \(level.localizedDescription)").tag(level)
                        }
                    }
                    .onChange(of: recordLevel) { newValue in
                        AppLog.shared.setMinimumLevel(newValue)
                        AppLog.ui.notice("记录等级调整为 \(newValue.tag)")
                    }
                    Button("恢复默认日志等级") {
                        AppLog.shared.resetMinimumLevel()
                        recordLevel = AppLog.shared.minimumLevel
                    }
                    .disabled(recordLevel == AppLog.defaultMinimumLevel)
                } header: {
                    Text("诊断与日志")
                } footer: {
                    Text("日志可查看、导出、复制或清除。低于所选等级的日志不会记录；排查 BMS 连接异常时建议临时调低到 DEBUG。")
                }
            }
            .navigationTitle("设置")
            .onAppear { recordLevel = AppLog.shared.minimumLevel }
        }
    }
}
