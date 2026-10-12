import Foundation

public enum ParameterPage: String, Codable, CaseIterable, Sendable {
    case dashboard, battery, controller
}

public enum ParameterSource: String, Codable, Sendable {
    case app, bms, controller
}

public enum ParameterCardSize: String, Codable, Sendable {
    case compact, wide, hero
}

/// 目录定义不写入用户偏好。sectionID 是真实来源/业务分类，不随拖动改变。
public struct ParameterMetricDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let unit: String
    public let source: ParameterSource
    public let sectionID: String
    public let size: ParameterCardSize

    public init(id: String, title: String, unit: String = "", source: ParameterSource,
                sectionID: String, size: ParameterCardSize = .compact) {
        self.id = id
        self.title = title
        self.unit = unit
        self.source = source
        self.sectionID = sectionID
        self.size = size
    }
}

public struct ParameterPlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: String { metricID }
    public var metricID: String
    public var sectionID: String
    public var size: ParameterCardSize
    public var isVisible: Bool

    public init(metricID: String, sectionID: String, size: ParameterCardSize = .compact,
                isVisible: Bool = true) {
        self.metricID = metricID
        self.sectionID = sectionID
        self.size = size
        self.isVisible = isVisible
    }
}

/// v3 独立保存每个页面的真实顺序；校验不再规范成固定槽位顺序。
public struct ParameterLayout: Codable, Equatable, Sendable {
    public let version: Int
    public let page: ParameterPage
    public var placements: [ParameterPlacement]

    public init(page: ParameterPage, placements: [ParameterPlacement]) {
        self.version = 3
        self.page = page
        self.placements = placements
    }

    public func visible(in sectionID: String) -> [ParameterPlacement] {
        placements.filter { $0.sectionID == sectionID && $0.isVisible }
    }

    public func placement(for metricID: String) -> ParameterPlacement? {
        placements.first { $0.metricID == metricID }
    }

    public func isValid(catalog: [ParameterMetricDescriptor]) -> Bool {
        let descriptors = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return version == 3 && Set(placements.map(\.metricID)).count == placements.count
            && placements.allSatisfy { placement in
                guard let descriptor = descriptors[placement.metricID] else { return false }
                return allows(descriptor, in: placement.sectionID)
            }
    }

    public func canMove(_ metricID: String, to sectionID: String,
                        catalog: [ParameterMetricDescriptor]) -> Bool {
        guard let placement = placement(for: metricID), placement.isVisible,
              let descriptor = catalog.first(where: { $0.id == metricID }) else { return false }
        return allows(descriptor, in: sectionID)
    }

    /// index 是删除前目标分类可见卡片的插入位置，与原生 drag/drop 的索引一致。
    public func moving(_ metricID: String, to sectionID: String, at index: Int,
                       catalog: [ParameterMetricDescriptor]) -> Self {
        guard isValid(catalog: catalog), canMove(metricID, to: sectionID, catalog: catalog),
              let original = placement(for: metricID),
              (0...visible(in: sectionID).count).contains(index) else { return self }
        let originalSection = visible(in: original.sectionID)
        let originalIndex = originalSection.firstIndex(where: { $0.metricID == metricID })
        var destination = index
        if original.sectionID == sectionID, let originalIndex, originalIndex < index {
            destination -= 1
        }
        var next = placements.filter { $0.metricID != metricID }
        let targets = next.filter { $0.sectionID == sectionID && $0.isVisible }
        var moved = original
        moved.sectionID = sectionID
        if sectionID != "top", let descriptor = catalog.first(where: { $0.id == metricID }) {
            moved.size = descriptor.size
        }
        let insertion: Int
        if destination < targets.count,
           let targetIndex = next.firstIndex(where: { $0.metricID == targets[destination].metricID }) {
            insertion = targetIndex
        } else {
            insertion = next.lastIndex(where: { $0.sectionID == sectionID }).map { $0 + 1 } ?? next.count
        }
        next.insert(moved, at: insertion)
        return checked(next, catalog: catalog)
    }

    public func settingVisibility(_ visible: Bool, for metricID: String,
                                  catalog: [ParameterMetricDescriptor]) -> Self {
        guard isValid(catalog: catalog), let index = placements.firstIndex(where: { $0.metricID == metricID }) else {
            return self
        }
        var next = placements
        next[index].isVisible = visible
        return checked(next, catalog: catalog)
    }

    public func adding(_ metricID: String, to sectionID: String,
                       catalog: [ParameterMetricDescriptor]) -> Self {
        guard isValid(catalog: catalog), let descriptor = catalog.first(where: { $0.id == metricID }),
              allows(descriptor, in: sectionID) else { return self }
        if let existing = placement(for: metricID), existing.isVisible { return self }
        var next = placements.filter { $0.metricID != metricID }
        next.append(ParameterPlacement(metricID: metricID, sectionID: sectionID, size: descriptor.size))
        return checked(next, catalog: catalog)
    }

    /// 与拖动分离。顶部接管底部时不跨来源交换：旧顶部卡归还真实分类。
    /// 只要用户未显式隐藏，替换不会丢弃原指标。
    public func replacing(_ metricID: String, with replacementID: String,
                          catalog: [ParameterMetricDescriptor]) -> Self {
        guard isValid(catalog: catalog), metricID != replacementID,
              let targetIndex = placements.firstIndex(where: { $0.metricID == metricID && $0.isVisible }),
              let oldDescriptor = catalog.first(where: { $0.id == metricID }),
              let newDescriptor = catalog.first(where: { $0.id == replacementID }),
              allows(newDescriptor, in: placements[targetIndex].sectionID) else { return self }
        let target = placements[targetIndex]
        let occupiedIndex = placements.firstIndex(where: { $0.metricID == replacementID && $0.isVisible })
        if let occupiedIndex {
            let occupied = placements[occupiedIndex]
            if !(page == .dashboard && target.sectionID == "top" && occupied.sectionID != "top") {
                guard allows(oldDescriptor, in: occupied.sectionID) else { return self }
                var next = placements
                next[targetIndex].metricID = replacementID
                next[occupiedIndex].metricID = metricID
                if target.sectionID != "top" { next[targetIndex].size = newDescriptor.size }
                if occupied.sectionID != "top" { next[occupiedIndex].size = oldDescriptor.size }
                return checked(next, catalog: catalog)
            }
        }
        // 保持目标所在的位置；删除被接管的唯一原卡（包括隐藏条目）。
        var next = placements.filter { $0.metricID != replacementID }
        guard let index = next.firstIndex(where: { $0.metricID == metricID }) else { return self }
        next[index] = ParameterPlacement(metricID: replacementID, sectionID: target.sectionID,
                                        size: target.sectionID == "top" ? target.size : newDescriptor.size)
        let returned = ParameterPlacement(metricID: metricID, sectionID: oldDescriptor.sectionID,
                                          size: oldDescriptor.size)
        // 兼容的被接管位置优先复用；不同来源归还其正确分类末尾。
        if let occupiedIndex, placements[occupiedIndex].sectionID == oldDescriptor.sectionID {
            let insertion = min(occupiedIndex, next.count)
            next.insert(returned, at: insertion)
        } else {
            let insertion = next.lastIndex(where: { $0.sectionID == oldDescriptor.sectionID }).map { $0 + 1 } ?? next.count
            next.insert(returned, at: insertion)
        }
        return checked(next, catalog: catalog)
    }

    /// 新上报通道追加；已配置/隐藏通道的顺序与显隐不会被设备数量变化重置。
    public func including(_ descriptors: [ParameterMetricDescriptor],
                          catalog: [ParameterMetricDescriptor]) -> Self {
        guard isValid(catalog: catalog) else { return self }
        var next = placements
        var known = Set(next.map(\.metricID))
        for descriptor in descriptors where catalog.contains(descriptor) && known.insert(descriptor.id).inserted {
            next.append(ParameterPlacement(metricID: descriptor.id, sectionID: descriptor.sectionID, size: descriptor.size))
        }
        return checked(next, catalog: catalog)
    }

    public func allows(_ descriptor: ParameterMetricDescriptor, in sectionID: String) -> Bool {
        switch page {
        case .dashboard:
            if sectionID == "top" { return true }
            if sectionID == "vehicle" && descriptor.source == .controller { return false }
            if sectionID == "controller" && descriptor.source != .controller { return false }
            guard sectionID == "vehicle" || sectionID == "controller" else { return false }
        case .battery:
            guard descriptor.source == .bms else { return false }
        case .controller:
            guard descriptor.source == .controller else { return false }
        }
        return sectionID == descriptor.sectionID
    }

    private func checked(_ placements: [ParameterPlacement], catalog: [ParameterMetricDescriptor]) -> Self {
        let next = Self(page: page, placements: placements)
        return next.isValid(catalog: catalog) ? next : self
    }
}

public struct ParameterEditSession: Equatable, Sendable {
    public private(set) var baseline: ParameterLayout
    public var draft: ParameterLayout
    public var isDirty: Bool { draft != baseline }

    public init(saved: ParameterLayout) {
        baseline = saved
        draft = saved
    }

    public mutating func cancel() { draft = baseline }
    public mutating func markSaved() { baseline = draft }
}
