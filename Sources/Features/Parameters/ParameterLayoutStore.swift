import ANTuRideDomain
import Foundation
import SwiftUI

struct ParameterLayoutPrefs {
    let defaults: UserDefaults
    init(defaults: UserDefaults = HomeParameterPrefs().defaults) { self.defaults = defaults }

    static func key(for page: ParameterPage) -> String { "parameter_layout_v3_\(page.rawValue)" }

    func load(_ page: ParameterPage) -> ParameterLayout {
        if let raw = defaults.string(forKey: Self.key(for: page)),
           let layout = Self.decode(raw, page: page) { return layout }
        if page == .dashboard {
            let legacy = defaults.string(forKey: HomeParameterPrefs.key).flatMap(HomeParameterPrefs.decode)
                ?? .androidDefault
            let layout = ParameterCatalog.migrating(legacy)
            // 只有新 key 不存在才迁移；不覆盖损坏原文，也不修改旧 v1/v2 JSON。
            if defaults.object(forKey: Self.key(for: page)) == nil { _ = save(layout) }
            return layout
        }
        return ParameterCatalog.defaultLayout(for: page)
    }

    @discardableResult
    func save(_ layout: ParameterLayout) -> Bool {
        guard layout.isValid(catalog: ParameterCatalog.metrics(for: layout.page)),
              let data = try? JSONEncoder().encode(layout),
              let raw = String(data: data, encoding: .utf8) else { return false }
        defaults.set(raw, forKey: Self.key(for: layout.page))
        return defaults.string(forKey: Self.key(for: layout.page)) == raw
    }

    static func decode(_ raw: String, page: ParameterPage) -> ParameterLayout? {
        guard let data = raw.data(using: .utf8),
              let layout = try? JSONDecoder().decode(ParameterLayout.self, from: data),
              layout.page == page, layout.isValid(catalog: ParameterCatalog.metrics(for: page)) else { return nil }
        return layout
    }
}

@MainActor
final class ParameterLayoutStore: ObservableObject {
    let page: ParameterPage
    let prefs: ParameterLayoutPrefs
    let catalog: [ParameterMetricDescriptor]
    @Published private(set) var saved: ParameterLayout
    @Published private(set) var session: ParameterEditSession?
    @Published private(set) var collapsedSections: Set<String>

    var isEditing: Bool { session != nil }
    var layout: ParameterLayout { session?.draft ?? saved }
    var isDirty: Bool { session?.isDirty == true }

    init(page: ParameterPage, defaults: UserDefaults = HomeParameterPrefs().defaults) {
        self.page = page
        prefs = ParameterLayoutPrefs(defaults: defaults)
        catalog = ParameterCatalog.metrics(for: page)
        saved = prefs.load(page)
        collapsedSections = Set(ParameterCatalog.sections(for: page).filter(\.initiallyCollapsed).map(\.id))
    }

    func beginEditing() { if session == nil { session = ParameterEditSession(saved: saved) } }
    func cancel() { session = nil }

    @discardableResult
    func finish() -> Bool {
        guard let session else { return true }
        guard !session.isDirty || prefs.save(session.draft) else { return false }
        saved = session.draft
        self.session = nil
        return true
    }

    func restoreDefaults() {
        guard session != nil else { return }
        let knownChannels = Set(saved.placements.filter { ParameterCatalog.isChannel($0.metricID) }.map(\.metricID))
        // 恢复默认时编号顺序来自目录，不沿用用户已拖动的单体/探头顺序。
        let channels = catalog.filter { knownChannels.contains($0.id) }
        session?.draft = ParameterCatalog.defaultLayout(for: page).including(channels, catalog: catalog)
    }

    func toggleSection(_ id: String) {
        if collapsedSections.contains(id) { collapsedSections.remove(id) }
        else { collapsedSections.insert(id) }
    }

    func move(_ id: String, to section: String, at index: Int) {
        guard session != nil else { return }
        session?.draft = layout.moving(id, to: section, at: index, catalog: catalog)
    }

    func moveToSource(_ id: String) {
        guard let descriptor = catalog.first(where: { $0.id == id }) else { return }
        move(id, to: descriptor.sectionID, at: layout.visible(in: descriptor.sectionID).count)
    }

    func moveToTop(_ id: String) {
        guard page == .dashboard else { return }
        move(id, to: "top", at: layout.visible(in: "top").count)
    }

    func hide(_ id: String) {
        guard session != nil else { return }
        session?.draft = layout.settingVisibility(false, for: id, catalog: catalog)
    }

    func add(_ id: String, to section: String) {
        guard session != nil else { return }
        session?.draft = layout.adding(id, to: section, catalog: catalog)
    }

    func replace(_ id: String, with replacement: String) {
        guard session != nil else { return }
        session?.draft = layout.replacing(id, with: replacement, catalog: catalog)
    }

    /// 通道发现独立合并进 baseline 与 draft，不会把未保存排序偷偷写入偏好。
    func includeReportedChannels(cellCount: Int, probeCount: Int) {
        guard page == .battery else { return }
        let channels = ParameterCatalog.reportedChannels(cellCount: cellCount, probeCount: probeCount)
        let nextSaved = saved.including(channels, catalog: catalog)
        guard nextSaved != saved, prefs.save(nextSaved) else { return }
        let nextDraft = session?.draft.including(channels, catalog: catalog)
        saved = nextSaved
        if let nextDraft {
            session = ParameterEditSession(saved: nextSaved)
            session?.draft = nextDraft
        }
    }
}
