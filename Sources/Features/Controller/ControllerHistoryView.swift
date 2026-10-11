import ANTuRideDomain
import SwiftUI

/// 由控制器 Tab 或设置页的现有 NavigationStack 挂载；不创建第二套导航栈。
struct ControllerHistoryView: View {
    @EnvironmentObject private var controller: ControllerBluetoothService
    @State private var deletionIDs: [UUID] = []
    @State private var confirmingDeletion = false
    @State private var unreadableCount = 0
    @State private var historyReadError: String?
    @State private var deletionError: String?

    var body: some View {
        List {
            Section {
                valueRow("记录状态", controller.isRecording ? "记录中" : "已停止")
                valueRow("已采样行数", "\(controller.recordedSampleCount)")
                if controller.isRecording { valueRow("剩余秒数", "\(controller.recordingSecondsRemaining)") }
                Button {
                    if controller.isRecording { controller.stopRecording() } else { controller.startRecording() }
                } label: {
                    Text(controller.isRecording ? "停止并保存记录" : "开始记录")
                        .frame(minHeight: 44)
                }
                .disabled(!controller.isRecording && (controller.state != .ready || controller.latestTelemetry == nil || controller.pendingRecord != nil))
                .accessibilityIdentifier("controller-record-toggle")
                if let pending = controller.pendingRecord {
                    Button { controller.savePendingRecord() } label: {
                        Text("重试保存内存中的记录").frame(minHeight: 44)
                    }
                    ControllerRecordExportButtons(record: pending, store: controller.historyStore)
                    Text("尚未保存：可先导出内存快照。分享不会清除待保存记录。")
                        .font(.footnote).foregroundStyle(AppTheme.warning)
                }
                if let warning = controller.recordingTimingWarning {
                    Text(warning).font(.footnote).foregroundStyle(AppTheme.warning)
                }
                if let error = controller.historyError { Text(error).foregroundStyle(AppTheme.danger) }
            } header: { Text("历史记录") } footer: {
                Text("只采集开始之后的新有效整帧，最多 30 分钟。重复或倒退的接收时间不改写，采样会被拒绝。断连或 App 退出前台时停止并保存；保存失败保留内存快照，退出进程仍可能丢失。")
            }
            Section {
                if controller.historyRecords.isEmpty { Text("暂无本地记录").foregroundStyle(.secondary) }
                ForEach(controller.historyRecords) { record in
                    NavigationLink {
                        ControllerHistoryDetailView(id: record.id, store: controller.historyStore)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.deviceName)
                            Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(record.samples.count) 行").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .onDelete { offsets in
                    deletionIDs = offsets.compactMap { index in
                        controller.historyRecords.indices.contains(index) ? controller.historyRecords[index].id : nil
                    }
                    confirmingDeletion = !deletionIDs.isEmpty
                }
                if unreadableCount > 0 {
                    Text("有 \(unreadableCount) 条历史记录读取失败；原文件已保留，其余记录仍可导出。")
                        .foregroundStyle(AppTheme.warning)
                }
                if let historyReadError { Text(historyReadError).foregroundStyle(AppTheme.danger) }
                if let deletionError { Text(deletionError).foregroundStyle(AppTheme.danger) }
                Button { refreshHistory() } label: {
                    Text("重新读取历史").frame(minHeight: 44)
                }
            } header: { Text("本地文件 · 左滑后确认删除") } footer: {
                Text("JSON 保存完整遥测并兼容旧记录；CSV/XLSX 对齐安卓 18 列，最新采样在前。旧记录保留已知值，缺失遥测显示 --，不补造温度、状态或车速。导出时间为 iPhone 接收时间的秒级文本；XLSX 不代表控制器硬件时钟精度。未实现 Android 历史导入。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("记录与历史")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshHistory() }
        .onChange(of: controller.historyRecords) { _ in inspectHistoryFailures() }
        .alert("删除控制器记录？", isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) { deletionIDs = [] }
            Button("删除", role: .destructive) { deleteConfirmedRecords() }
        } message: {
            Text("将删除 \(deletionIDs.count) 条本地记录，无法撤销；已导出的分享文件不受影响。")
        }
    }

    private func refreshHistory() {
        controller.refreshHistory()
        inspectHistoryFailures()
    }

    private func inspectHistoryFailures() {
        do {
            unreadableCount = try controller.historyStore.loadAllReportingFailures().unreadableRecordIDs.count
            historyReadError = nil
        } catch {
            historyReadError = "历史读取失败：\(error.localizedDescription)"
        }
    }

    private func deleteConfirmedRecords() {
        var failures: [String] = []
        for id in deletionIDs {
            controller.deleteRecord(id: id)
            if let error = controller.historyError { failures.append(error) }
        }
        deletionIDs = []
        deletionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        inspectHistoryFailures()
    }
}

private struct ControllerHistoryDetailView: View {
    let id: UUID
    let store: ControllerHistoryStore
    @State private var record: ControllerHistoryRecord?
    @State private var errorText: String?

    var body: some View {
        List {
            if let record {
                Section("记录信息") {
                    valueRow("设备", record.deviceName)
                    Text(record.deviceID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                    Text(record.endedAt, format: .dateTime.year().month().day().hour().minute().second())
                    valueRow("采样行数", "\(record.samples.count)")
                    if let warning = record.timingWarning {
                        Text(warning).font(.footnote).foregroundStyle(AppTheme.warning)
                    }
                    Text("时间取自 iPhone 接收时刻；CSV/XLSX 仅显示到秒，不代表控制器硬件时钟精度。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ControllerRecordExportButtons(record: record, store: store)
                }
                Section("采样 · 时间升序") {
                    ForEach(record.samples.indices, id: \.self) { index in
                        let sample = record.samples[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sample.timestamp, format: .dateTime.hour().minute().second())
                            Text("\(controllerNumber(sample.voltage, unit: "V")) · \(controllerNumber(sample.current, unit: "A")) · \(sample.rpm) RPM")
                            Text("转把 \(controllerNumber(sample.throttle, unit: "V")) · 刹车 \(controllerNumber(sample.brake, unit: "V")) · 车速 --")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let errorText { Text(errorText).foregroundStyle(AppTheme.danger) }
        }
        .navigationTitle("控制器历史详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { record = try store.load(id: id); errorText = nil }
            catch { errorText = "记录读取失败：\(error.localizedDescription)" }
        }
    }
}

/// Persistent and unsaved records share the same isolated export/sheet lifecycle.
private struct ControllerRecordExportButtons: View {
    let record: ControllerHistoryRecord
    let store: ControllerHistoryStore
    @State private var errorText: String?
    @State private var exportURL: URL?
    @State private var showingExport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(ControllerHistoryStore.ExportFormat.allCases, id: \.self) { format in
                    Button { export(format) } label: {
                        Text("导出 \(format.rawValue.uppercased())").frame(minHeight: 44)
                    }
                }
            } label: {
                Text("导出并分享").frame(minHeight: 44)
            }
            .disabled(showingExport)
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(AppTheme.danger) }
        }
        .sheet(isPresented: $showingExport, onDismiss: {
            // exportForSharing owns this unique directory; never remove history or another snapshot.
            if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
            exportURL = nil
        }) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
    }

    private func export(_ format: ControllerHistoryStore.ExportFormat) {
        do {
            exportURL = try store.exportForSharing(record, format: format)
            errorText = nil
            showingExport = true
        } catch { errorText = "记录导出失败：\(error.localizedDescription)" }
    }
}

private func controllerNumber(_ value: Double?, unit: String) -> String {
    guard let value, value.isFinite else { return "--" }
    return String(format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"), value, unit)
}

private func valueRow(_ title: String, _ value: String) -> some View {
    LabeledContent(title) {
        Text(value).monospacedDigit().multilineTextAlignment(.trailing)
    }
}
