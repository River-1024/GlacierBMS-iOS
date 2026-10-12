import ANTuRideDomain
import SwiftUI

private struct ParameterPickerRequest: Identifiable {
    let sectionID: String
    let replacementID: String?
    var id: String { replacementID ?? "add.\(sectionID)" }
}

/// 三 Tab 共用原生网格和草稿编辑。固定状态/曲线/导航入口不是可拖指标。
@MainActor
struct ParameterCardPage: View {
    @ObservedObject var store: ParameterLayoutStore
    var leadingContent: AnyView? = nil
    var middleContent: AnyView? = nil
    var trailingContent: AnyView? = nil
    var availableMetricIDs: Set<String>? = nil
    var valueScale: Double = 1
    var card: (ParameterPlacement) -> AnyView
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var picker: ParameterPickerRequest?
    @State private var confirmsRestore = false
    @State private var saveFailed = false

    private var pageID: String { store.page.rawValue }
    private var definitions: [ParameterSectionDefinition] { ParameterCatalog.sections(for: store.page) }
    private var firstMetricID: String? {
        definitions.flatMap { shown(in: $0.id) }.first?.metricID
    }

    var body: some View {
        NativeParameterGrid(sections: gridSections, isEditing: store.isEditing,
                            usesSingleColumn: dynamicTypeSize.isAccessibilitySize || valueScale >= 1.5,
                            accessibilityIdentifier: "\(pageID).parameter-content", content: gridContent,
                            canMove: { store.layout.canMove($0, to: $1, catalog: store.catalog) },
                            onMove: { id, section, index in
                                move(id, section, index)
                                return gridSections
                            })
            .background(AppTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.isEditing { editorBar }
            }
            .sheet(item: $picker) { request in
                ParameterMetricPicker(store: store, request: request, availableMetricIDs: availableMetricIDs)
            }
            .confirmationDialog("恢复当前页面默认布局？", isPresented: $confirmsRestore, titleVisibility: .visible) {
                Button("恢复默认", role: .destructive) { store.restoreDefaults() }
                    .accessibilityIdentifier("\(pageID).restore.confirm")
                Button("取消", role: .cancel) {}
                    .accessibilityIdentifier("\(pageID).restore.cancel")
            } message: {
                Text("仅修改当前页面草稿；点击完成后保存，不影响其他 Tab 或设备参数。")
            }
            .alert("布局保存失败", isPresented: $saveFailed) {
                Button("确定", role: .cancel) {}
            } message: { Text("原布局未改变，请重试。") }
    }

    private func shown(in section: String) -> [ParameterPlacement] {
        store.layout.visible(in: section).filter { availableMetricIDs?.contains($0.metricID) ?? true }
    }

    private var gridSections: [ParameterGridSection] {
        var result: [ParameterGridSection] = []
        if leadingContent != nil {
            result.append(.init(id: "fixed.leading", items: [.init(id: "fixed.leading", isDraggable: false, fullWidth: true)]))
        }
        if firstMetricID == nil && !store.isEditing {
            result.append(.init(id: "fixed.empty", items: [.init(id: "fixed.empty", isDraggable: false, fullWidth: true)]))
        }
        for definition in definitions {
            let placements = shown(in: definition.id)
            let collapsible = definition.initiallyCollapsed
            if !placements.isEmpty || store.isEditing {
                var items: [ParameterGridItem] = []
                if collapsible && !store.isEditing {
                    items.append(.init(id: "toggle.\(definition.id)", isDraggable: false, fullWidth: true))
                }
                if store.isEditing || !store.collapsedSections.contains(definition.id) {
                    items += placements.map { .init(id: $0.id, fullWidth: $0.size != .compact) }
                }
                if store.isEditing {
                    items.append(.init(id: "add.\(definition.id)", isDraggable: false, fullWidth: true))
                }
                let title = definition.id == "top" || (collapsible && !store.isEditing) ? nil : definition.title
                result.append(.init(id: definition.id, title: title, items: items))
            }
            if definition.id == "top", middleContent != nil {
                result.append(.init(id: "fixed.middle", items: [.init(id: "fixed.middle", isDraggable: false, fullWidth: true)]))
            }
        }
        if trailingContent != nil {
            result.append(.init(id: "fixed.trailing", items: [.init(id: "fixed.trailing", isDraggable: false, fullWidth: true)]))
        }
        return result
    }

    private func gridContent(_ id: String) -> AnyView {
        switch id {
        case "fixed.leading": return leadingContent ?? AnyView(EmptyView())
        case "fixed.middle": return middleContent ?? AnyView(EmptyView())
        case "fixed.trailing": return trailingContent ?? AnyView(EmptyView())
        case "fixed.empty":
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Text("暂无显示参数").font(.headline)
                Text("长按编辑布局").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding()
                .contentShape(Rectangle())
                .contextMenu {
                    Button("编辑布局") { store.beginEditing() }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: Text("编辑布局")) { store.beginEditing() }
                .accessibilityIdentifier("\(pageID).empty-layout"))
        default: break
        }
        if let definition = definitions.first(where: { "toggle.\($0.id)" == id }) {
            return AnyView(Button { store.toggleSection(definition.id) } label: {
                HStack {
                    Text(definition.title).font(.headline)
                    Spacer()
                    Image(systemName: store.collapsedSections.contains(definition.id) ? "chevron.down" : "chevron.up")
                }.frame(minHeight: 44)
            }.accessibilityLabel("\(definition.title)，\(store.collapsedSections.contains(definition.id) ? "展开" : "收起")")
                .accessibilityIdentifier("\(pageID).section.\(definition.id)"))
        }
        if let definition = definitions.first(where: { "add.\($0.id)" == id }) {
            return AnyView(Button {
                picker = ParameterPickerRequest(sectionID: definition.id, replacementID: nil)
            } label: {
                Label("添加参数", systemImage: "plus.circle").frame(maxWidth: .infinity, minHeight: 44)
            }.accessibilityLabel("向\(definition.title)添加参数")
                .accessibilityIdentifier("\(pageID).add.\(definition.id)"))
        }
        guard let placement = store.layout.placement(for: id) else { return AnyView(EmptyView()) }
        return AnyView(editableCard(placement))
    }

    @ViewBuilder
    private func editableCard(_ placement: ParameterPlacement) -> some View {
        if store.isEditing {
            if store.page == .dashboard {
                editingAccessibleCard(placement)
                    .accessibilityAction(named: Text(placement.sectionID == "top" ? "归还来源分组" : "移至重点参数")) {
                        if placement.sectionID == "top" { store.moveToSource(placement.id) }
                        else { store.moveToTop(placement.id) }
                    }
            } else {
                editingAccessibleCard(placement)
            }
        } else {
            metricCardBody(placement)
                .accessibilityAction(named: Text("编辑布局")) { store.beginEditing() }
        }
    }

    private func editingAccessibleCard(_ placement: ParameterPlacement) -> some View {
        metricCardBody(placement)
            .accessibilityAction(named: Text("向前移动")) { moveRelative(placement, offset: -1) }
            .accessibilityAction(named: Text("向后移动")) { moveRelative(placement, offset: 1) }
            .accessibilityAction(named: Text("隐藏参数")) { store.hide(placement.id) }
    }

    private func metricCardBody(_ placement: ParameterPlacement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.isEditing {
                HStack(spacing: 8) {
                    Label("长按拖动", systemImage: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Menu {
                        Button("替换参数") {
                            picker = ParameterPickerRequest(sectionID: placement.sectionID, replacementID: placement.id)
                        }.accessibilityIdentifier("\(pageID).action.\(placement.id).replace")
                        Button("向前移动") { moveRelative(placement, offset: -1) }
                            .accessibilityIdentifier("\(pageID).action.\(placement.id).backward")
                        Button("向后移动") { moveRelative(placement, offset: 1) }
                            .accessibilityIdentifier("\(pageID).action.\(placement.id).forward")
                        if store.page == .dashboard {
                            if placement.sectionID == "top" {
                                Button("归还来源分组") { store.moveToSource(placement.id) }
                                    .accessibilityIdentifier("\(pageID).action.\(placement.id).source")
                            } else {
                                Button("移至重点参数") { store.moveToTop(placement.id) }
                                    .accessibilityIdentifier("\(pageID).action.\(placement.id).top")
                            }
                        }
                        Button("隐藏参数") { store.hide(placement.id) }
                            .accessibilityIdentifier("\(pageID).action.\(placement.id).hide")
                    } label: {
                        Label("卡片操作", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("\(pageID).actions.\(placement.id)")
                }.padding(.horizontal, 12)
            }
            card(placement)
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            if !store.isEditing { Button("编辑布局") { store.beginEditing() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(pageID).metric.\(placement.id)")
    }

    /// 显示中的通道子集索引映射回完整持久化顺序，不丢弃暂时未上报的通道。
    private func move(_ id: String, _ section: String, _ index: Int) {
        let shown = shown(in: section)
        let all = store.layout.visible(in: section)
        let destination = index < shown.count
            ? all.firstIndex(where: { $0.id == shown[index].id }) ?? all.count : all.count
        store.move(id, to: section, at: destination)
    }

    private func moveRelative(_ placement: ParameterPlacement, offset: Int) {
        let cards = shown(in: placement.sectionID)
        guard let index = cards.firstIndex(where: { $0.id == placement.id }) else { return }
        let target = offset < 0 ? index - 1 : index + 2
        guard (0...cards.count).contains(target) else { return }
        move(placement.id, placement.sectionID, target)
    }

    private var editorBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("编辑显示布局，不修改设备参数").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { editorActions }
                VStack(alignment: .leading, spacing: 4) { editorActions }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    @ViewBuilder private var editorActions: some View {
        Button("取消") { store.cancel() }.frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("\(pageID).cancel")
        Button("恢复默认") { confirmsRestore = true }.frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("\(pageID).restore")
        Button("完成") { if !store.finish() { saveFailed = true } }
            .fontWeight(.semibold).frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("\(pageID).save")
    }
}

@MainActor
private struct ParameterMetricPicker: View {
    @ObservedObject var store: ParameterLayoutStore
    let request: ParameterPickerRequest
    let availableMetricIDs: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [ParameterMetricDescriptor] {
        store.catalog.filter { descriptor in
            (availableMetricIDs?.contains(descriptor.id) ?? true)
                && store.layout.allows(descriptor, in: request.sectionID)
                && (query.isEmpty || descriptor.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { descriptor in
                        let enabled = isEnabled(descriptor)
                        Button {
                            if let id = request.replacementID { store.replace(id, with: descriptor.id) }
                            else { store.add(descriptor.id, to: request.sectionID) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(descriptor.title)
                                Spacer()
                                if store.layout.placement(for: descriptor.id)?.isVisible == true {
                                    Text(request.replacementID == nil ? "已添加" : "已在页面中").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(minHeight: 44)
                        }.disabled(!enabled)
                            .accessibilityIdentifier("\(store.page.rawValue).candidate.\(descriptor.id)")
                    }
                } footer: {
                    Text(request.replacementID == nil ? "已添加的指标不能重复创建。"
                         : "替换与拖动排序分开；旧指标保留，首页顶部旧指标自动归还所属来源分组。")
                }
            }
            .searchable(text: $query, prompt: "搜索参数")
            .navigationTitle(request.replacementID == nil ? "添加参数" : "替换参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    private func isEnabled(_ descriptor: ParameterMetricDescriptor) -> Bool {
        if let id = request.replacementID {
            return store.layout.replacing(id, with: descriptor.id, catalog: store.catalog) != store.layout
        }
        return store.layout.placement(for: descriptor.id)?.isVisible != true
    }
}
