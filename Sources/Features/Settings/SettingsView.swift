import SwiftUI

/// 设置页。当前承载日志管理，后续可扩展校准、续航参数等。
struct SettingsView: View {
    @State private var recordLevel: LogLevel = AppLog.shared.minimumLevel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LogViewerView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("运行日志")
                                Text("查看、导出、复制与清除 App 日志")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("连接 BMS 出现异常时，可在运行日志中查看完整链路记录并导出。")
                }

                Section {
                    Picker("记录等级", selection: $recordLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text("\(level.tag) — \(level.localizedDescription)").tag(level)
                        }
                    }
                    .onChange(of: recordLevel) { newValue in
                        AppLog.shared.setMinimumLevel(newValue)
                        AppLog.ui.notice("记录等级调整为 \(newValue.tag)")
                    }

                    Button("恢复默认等级") {
                        AppLog.shared.resetMinimumLevel()
                        recordLevel = AppLog.shared.minimumLevel
                    }
                    .disabled(recordLevel == AppLog.shared.minimumLevel)
                } header: {
                    Text("记录阈值")
                } footer: {
                    Text("低于所选等级的日志不会被记录，也不会写入文件。排查问题时建议临时调低到 DEBUG。")
                }

                Section {
                    PlaceholderRow(title: "电池校准", message: "阶段 3 接入")
                    PlaceholderRow(title: "续航参数", message: "阶段 3 接入")
                    PlaceholderRow(title: "本地导出", message: "阶段 3 接入")
                } header: {
                    Text("后续功能")
                }
            }
            .navigationTitle("设置")
        }
    }
}

private struct PlaceholderRow: View {
    let title: String
    let message: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
