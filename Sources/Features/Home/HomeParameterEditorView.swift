import SwiftUI

/// 首页槽位编辑器仅从设置进入；选择和恢复默认只修改草稿，显式保存后生效。
struct HomeParameterEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: HomeParameterEditSession
    @State private var saveFailed = false
    @State private var showsRestoreConfirmation = false

    private let prefs: HomeParameterPrefs
    private let onSave: ((HomeParameterConfig) -> Void)?

    init(
        config: HomeParameterConfig? = nil,
        prefs: HomeParameterPrefs = HomeParameterPrefs(),
        onSave: ((HomeParameterConfig) -> Void)? = nil
    ) {
        let initialConfig = config ?? prefs.loadForHome()
        _session = State(initialValue: HomeParameterEditSession.start(saved: initialConfig.forHome))
        self.prefs = prefs
        self.onSave = onSave
    }

    var body: some View {
        List {
            ForEach(HomeParameterRegion.allCases, id: \.self) { region in
                Section {
                    ForEach(session.draft.assignments(in: region)) { assignment in
                        NavigationLink {
                            HomeParameterCandidateView(session: $session, slotId: assignment.slotId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(HomeParameterMetricDefinition.definition(for: assignment.metricId)?.title ?? assignment.metricId)
                                Text(assignment.slotId)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("home.slot.\(assignment.slotId)")
                    }
                } header: {
                    Text(region.title)
                } footer: {
                    if region == .top {
                        Text("点击替换指标。接管底部指标会删除原底槽，旧顶部指标自动归还所属来源区；顶部之间交换。")
                    } else {
                        Text("底部按来源隔离；新增归还槽随配置保存。未接入数据的指标显示 --。")
                    }
                }
            }

            Section {
                Button("恢复默认") {
                    showsRestoreConfirmation = true
                }
                .disabled(session.draft == .androidDefault)
                .accessibilityIdentifier("home.restore")
            }
        }
        .navigationTitle("首页参数")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    session = session.cancel()
                    dismiss()
                }
                .accessibilityIdentifier("home.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
                .disabled(!session.isDirty)
                .accessibilityIdentifier("home.save")
            }
        }
        .confirmationDialog("恢复默认首页参数？", isPresented: $showsRestoreConfirmation, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                session = session.restoreDefaults()
            }
            .accessibilityIdentifier("home.restore.confirm")
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("home.restore.cancel")
        } message: {
            Text("将当前草稿恢复为默认槽位；保存后才会替换已保存布局。")
        }
        .alert("保存失败", isPresented: $saveFailed) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("首页配置无效，未写入偏好设置。")
        }
    }

    private func save() {
        guard prefs.save(session.draft) else {
            saveFailed = true
            return
        }
        session = session.markSaved()
        onSave?(session.baseline)
        dismiss()
    }
}

/// 所有候选都调用模型的 candidate：不可选的原因和应用结果不在 UI 另算。
private struct HomeParameterCandidateView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var session: HomeParameterEditSession
    let slotId: String

    var body: some View {
        List {
            ForEach(HomeParameterSource.allCases, id: \.self) { source in
                Section(source == .app ? "APP" : source == .bms ? "BMS" : "控制器") {
                    ForEach(HomeParameterMetricDefinition.all.filter { $0.source == source }) { metric in
                        let candidate = session.draft.candidate(slotId: slotId, metricId: metric.id)
                        Button {
                            session = session.select(slotId: slotId, metricId: metric.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.title)
                                Text(candidate.disabledReason ?? candidate.kind.title)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let occupied = candidate.occupiedSlotId {
                                    Text("占用框：\(occupied)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(candidate.kind == .disabled || candidate.kind == .current)
                        .accessibilityIdentifier("home.candidate.\(metric.id)")
                    }
                }
            }
        }
        .navigationTitle("选择指标")
        .navigationBarTitleDisplayMode(.inline)
    }
}
