import SwiftUI

/// 首页参数编辑器。调用方传入当前配置；未传入时从独立 UserDefaults 加载。
///
/// 接入约定：
/// - 用 `HomeParameterPrefs().load()` 获取 `HomeParameterConfig`；
/// - 用 `config.visibleCards` 或 `config.cards` 的顺序驱动首页渲染；
/// - 在设置页/首页入口呈现此 View；保存成功后通过 `onSave` 接收新配置。
struct HomeParameterEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: HomeParameterEditSession
    @State private var saveFailed = false

    private let prefs: HomeParameterPrefs
    private let onSave: ((HomeParameterConfig) -> Void)?

    init(
        config: HomeParameterConfig? = nil,
        prefs: HomeParameterPrefs = HomeParameterPrefs(),
        onSave: ((HomeParameterConfig) -> Void)? = nil
    ) {
        let initialConfig = config ?? prefs.loadForHome()
        _session = State(initialValue: HomeParameterEditSession.start(saved: initialConfig))
        self.prefs = prefs
        self.onSave = onSave
    }

    var body: some View {
        List {
            Section {
                Toggle("安卓槽位布局（27 默认槽 / 39 指标）", isOn: Binding(
                    get: { session.draft.usesSlotLayout },
                    set: { session = session.usingSlotLayout($0) }
                ))
            } footer: {
                Text("横竖屏共用一份布局。关闭后使用原 10 卡片模式；旧卡片排序和显隐保留。模式切换也需保存。")
            }

            if session.draft.usesSlotLayout {
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
            } else {
                Section {
                    ForEach(session.draft.cards) { placement in
                        let definition = HomeParameterCardDefinition.definition(for: placement.id)
                        Toggle(isOn: visibilityBinding(for: placement.id)) {
                            Label(definition.title, systemImage: definition.systemImage)
                        }
                        .accessibilityIdentifier("home.card.\(placement.id.rawValue)")
                    }
                    .onMove { offsets, destination in
                        session = session.moving(fromOffsets: offsets, toOffset: destination)
                    }
                } header: {
                    Text("旧版首页卡片")
                } footer: {
                    Text("拖动调整顺序；关闭开关后隐藏。连接状态和行程控制固定显示。")
                }
            }

            Section {
                Button("恢复默认") {
                    session = session.restoreDefaults()
                }
                .disabled(session.draft == (session.draft.usesSlotLayout ? HomeParameterConfig.androidDefault : .default))
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("首页参数")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    session = session.cancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
                .disabled(!session.isDirty)
            }
        }
        .alert("保存失败", isPresented: $saveFailed) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("首页配置无效，未写入偏好设置。")
        }
    }

    private func visibilityBinding(for id: HomeParameterCardID) -> Binding<Bool> {
        Binding(
            get: { session.draft.isVisible(id) },
            set: { session = session.settingVisibility($0, for: id) }
        )
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
