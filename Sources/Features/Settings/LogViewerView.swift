import SwiftUI
import UniformTypeIdentifiers

/// 日志查看与管理页。满足四项核心能力：查看 / 导出下载 / 清除 / 复制。
struct LogViewerView: View {
    @StateObject private var store = LogStore()
    @State private var showClearConfirm = false
    @State private var showCopiedToast = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        List {
            controlSection
            levelFilterSection
            contentSection
            if let message = store.lastActionMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("已复制到剪贴板")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .onAppear { store.reload() }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .alert("清空全部日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                store.clearAll()
            }
        } message: {
            Text("此操作会删除设备上的全部日志文件，且不可恢复。建议先导出备份。")
        }
    }

    // MARK: - 顶部操作区

    private var controlSection: some View {
        Section {
            HStack {
                Label("日志占用", systemImage: "internaldrive")
                Spacer()
                Text(store.totalSizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Label("条目数", systemImage: "list.bullet")
                Spacer()
                Text("\(store.entries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                // 先做一次同步导出，再弹出系统分享面板（含「存储到文件」即下载）。
                exportURL = store.exportFileURL()
                showShareSheet = exportURL != nil
            } label: {
                Label("导出 / 下载日志", systemImage: "square.and.arrow.up")
            }
            .disabled(store.entries.isEmpty)

            Button {
                UIPasteboard.general.string = store.copyText()
                withAnimation { showCopiedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { showCopiedToast = false }
                }
            } label: {
                Label("复制全部日志", systemImage: "doc.on.doc")
            }
            .disabled(store.entries.isEmpty)

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空全部日志", systemImage: "trash")
            }
            .disabled(store.entries.isEmpty)
        } header: {
            Text("管理")
        }
    }

    // MARK: - 等级筛选

    private var levelFilterSection: some View {
        Section {
            Picker("最低等级", selection: Binding(
                get: { store.filterLevel },
                set: { store.setFilterLevel($0) }
            )) {
                Text("全部").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text("\(level.tag) 及以上").tag(LogLevel?.some(level))
                }
            }
        } header: {
            Text("筛选")
        } footer: {
            Text(filterFooter)
        }
    }

    private var filterFooter: String {
        let current = AppLog.shared.minimumLevel
        return "当前记录阈值：\(current.tag)（\(current.localizedDescription)）。筛选只影响本页显示，不改变记录行为。"
    }

    // MARK: - 日志内容

    private var contentSection: some View {
        Section {
            if store.isLoading && store.entries.isEmpty {
                HStack {
                    ProgressView()
                    Text("正在加载…").foregroundStyle(.secondary)
                }
            } else if store.entries.isEmpty {
                Text("暂无日志")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.entries) { entry in
                    LogEntryRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text("日志内容")
                Spacer()
                if store.entries.count >= store.maximumLoadedEntries {
                    Text("仅显示最近 \(store.maximumLoadedEntries) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 单条日志行：等级着色 + 时间 + 分类 + 消息。长按可复制单条。
private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.tag)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(levelColor)
                Text(entry.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(LogEntry.exportFormatter.string(from: entry.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.exportedText()
            } label: {
                Label("复制此条", systemImage: "doc.on.doc")
            }
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .green
        case .warning: return .orange
        case .error: return .red
        case .fault: return .purple
        }
    }
}

/// `UIActivityViewController` 的 SwiftUI 包装，用于导出/下载日志文件。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
