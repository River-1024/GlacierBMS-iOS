import Foundation

/// 首页可配置卡片的稳定标识。标识同时用于排序、显隐和持久化，不依赖本地化标题。
enum HomeParameterCardID: String, CaseIterable, Codable, Hashable, Identifiable {
    case speed
    case range
    case stateOfCharge
    case remainingCapacity
    case power
    case current
    case voltage
    case capacityAndHealth
    case status
    case currentChart

    var id: Self { self }
}

/// 首页卡片的静态定义。运行时数据仍由 Dashboard 提供，本模型只描述布局。
struct HomeParameterCardDefinition: Equatable, Identifiable {
    let id: HomeParameterCardID
    let title: String
    let systemImage: String

    static let all: [Self] = [
        Self(id: .speed, title: "速度", systemImage: "speedometer"),
        Self(id: .range, title: "综合续航", systemImage: "arrow.triangle.2.circlepath"),
        Self(id: .stateOfCharge, title: "SOC", systemImage: "battery.75percent"),
        Self(id: .remainingCapacity, title: "剩余电量", systemImage: "battery.25percent"),
        Self(id: .power, title: "功率", systemImage: "bolt"),
        Self(id: .current, title: "电流", systemImage: "gauge.with.dots.needle.67percent"),
        Self(id: .voltage, title: "总电压", systemImage: "bolt.horizontal"),
        Self(id: .capacityAndHealth, title: "总容量 / SOH", systemImage: "chart.bar.xaxis"),
        Self(id: .status, title: "状态", systemImage: "checkmark.shield"),
        Self(id: .currentChart, title: "电流曲线", systemImage: "chart.xyaxis.line")
    ]

    static func definition(for id: HomeParameterCardID) -> Self {
        all.first { $0.id == id }!
    }
}

/// 一个卡片的布局状态。卡片定义本身不写入偏好，避免标题变更破坏用户布局。
struct HomeParameterCardPlacement: Codable, Equatable, Identifiable {
    let id: HomeParameterCardID
    var isVisible: Bool

    init(id: HomeParameterCardID, isVisible: Bool = true) {
        self.id = id
        self.isVisible = isVisible
    }
}

/// 首页卡片的完整布局：数组顺序是显示顺序，isVisible 决定是否显示。
struct HomeParameterConfig: Codable, Equatable {
    var cards: [HomeParameterCardPlacement]
    /// nil 仅用于解码旧十卡片配置；首页运行时通过 forHome 统一使用槽位。
    var assignments: [HomeParameterAssignment]? = nil

    static let androidDefault = Self(cards: Self.default.cards, assignments: HomeParameterSlotDefinition.all.map {
        HomeParameterAssignment(slotId: $0.id, metricId: $0.defaultMetricId)
    })

    var usesSlotLayout: Bool { assignments != nil }

    /// 旧卡片配置只保留解码兼容性，不再驱动首页或编辑器。
    /// 有效定制保留全部分配（包括动态归还槽），仅规范显示顺序。
    var forHome: Self {
        guard isValid(), usesSlotLayout else { return .androidDefault }
        return normalized()
    }

    static let `default` = Self(cards: HomeParameterCardID.allCases.map { HomeParameterCardPlacement(id: $0) })

    var visibleCardIDs: [HomeParameterCardID] {
        cards.filter(\.isVisible).map(\.id)
    }

    var visibleCards: [HomeParameterCardDefinition] {
        visibleCardIDs.map { HomeParameterCardDefinition.definition(for: $0) }
    }

    func isVisible(_ id: HomeParameterCardID) -> Bool {
        cards.first { $0.id == id }?.isVisible ?? false
    }

    func isValid() -> Bool {
        let ids = cards.map(\.id)
        return ids.count == HomeParameterCardID.allCases.count
            && Set(ids) == Set(HomeParameterCardID.allCases)
            && (assignments == nil || hasValidAssignments())
    }

    func settingVisibility(_ isVisible: Bool, for id: HomeParameterCardID) -> Self {
        var copy = self
        guard let index = copy.cards.firstIndex(where: { $0.id == id }) else { return self }
        copy.cards[index].isVisible = isVisible
        return copy
    }

    func moving(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Self {
        // List 的目标位置以移动前的数组为准；模型保持 Foundation-only，
        // 不依赖 SwiftUI 的 Array.move，也不让无效偏移破坏布局。
        guard !offsets.isEmpty,
              (0...cards.count).contains(destination),
              offsets.allSatisfy({ cards.indices.contains($0) }) else { return self }
        let moved = offsets.map { cards[$0] }
        var remaining = cards.enumerated().filter { !offsets.contains($0.offset) }.map { $0.element }
        let insertionIndex = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: insertionIndex)
        return Self(cards: remaining, assignments: assignments)
    }
}

/// 首页参数编辑会话：baseline 是已保存配置，draft 是未提交草稿。
struct HomeParameterEditSession: Equatable {
    let baseline: HomeParameterConfig
    var draft: HomeParameterConfig

    var isDirty: Bool { baseline != draft }

    static func start(saved: HomeParameterConfig) -> Self {
        let valid = saved.isValid() ? saved : .default
        return Self(baseline: valid, draft: valid)
    }

    func settingVisibility(_ isVisible: Bool, for id: HomeParameterCardID) -> Self {
        var copy = self
        copy.draft = draft.settingVisibility(isVisible, for: id)
        return copy
    }

    func moving(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Self {
        var copy = self
        copy.draft = draft.moving(fromOffsets: offsets, toOffset: destination)
        return copy
    }

    func restoreDefaults() -> Self {
        Self(baseline: baseline, draft: draft.usesSlotLayout ? .androidDefault : .default)
    }

    func cancel() -> Self {
        Self(baseline: baseline, draft: baseline)
    }

    func markSaved() -> Self {
        Self(baseline: draft, draft: draft)
    }
}

/// 首页布局的独立 UserDefaults 存储。任何损坏配置都整套回退默认值。
struct HomeParameterPrefs {
    static let key = "home_parameter_layout_v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = HomeParameterPrefs.homeDefaults) {
        self.defaults = defaults
    }

    func load() -> HomeParameterConfig {
        guard let raw = defaults.string(forKey: Self.key), let decoded = Self.decode(raw) else {
            return .default
        }
        return decoded
    }

    /// 编辑器和 Dashboard 共用存储；DEBUG UI 回归使用独立套件并支持重启。
    static var homeDefaults: UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["ANTURIDE_UI_TEST_HOME_SUITE"],
           suite.hasPrefix("UITest-Home-"), let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }

    /// 首页加载边界迁移旧配置；有效槽位定制不重写，坏数据仅回退显示。
    func loadForHome() -> HomeParameterConfig {
        guard let decoded = Self.decode(defaults.string(forKey: Self.key)) else { return .androidDefault }
        let config = decoded.forHome
        if !decoded.usesSlotLayout { save(config) }
        return config
    }

    @discardableResult
    func save(_ config: HomeParameterConfig) -> Bool {
        guard config.isValid(), let encoded = Self.encode(config) else { return false }
        defaults.set(encoded, forKey: Self.key)
        return true
    }

    static func encode(_ config: HomeParameterConfig) -> String? {
        guard config.isValid() else { return nil }
        let payload = StoredPayload(version: config.usesSlotLayout ? 2 : 1, cards: config.cards, assignments: config.assignments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? String(decoding: encoder.encode(payload), as: UTF8.self)
    }

    static func decode(_ raw: String?) -> HomeParameterConfig? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let payload = try? JSONDecoder().decode(StoredPayload.self, from: data) else { return nil }
        if payload.version == 1, let cards = payload.cards, payload.assignments == nil {
            let config = HomeParameterConfig(cards: cards)
            return config.isValid() ? config : nil
        }
        // 安卓 v1 必须完整 27 个固定槽；v2 允许删除默认底槽和动态归还。
        guard payload.version == 1 || payload.version == 2,
              let assignments = payload.assignments else { return nil }
        if payload.version == 1 {
            guard payload.cards == nil, assignments.count == HomeParameterSlotDefinition.all.count,
                  Set(assignments.map(\.slotId)) == Set(HomeParameterSlotDefinition.all.map(\.id)) else { return nil }
        }
        let config = HomeParameterConfig(cards: payload.cards ?? HomeParameterConfig.default.cards, assignments: assignments)
        guard config.isValid() else { return nil }
        return config.normalized()
    }

    private struct StoredPayload: Codable {
        let version: Int
        let cards: [HomeParameterCardPlacement]?
        let assignments: [HomeParameterAssignment]?
    }
}



// MARK: - 安卓槽位配置（与 HomeParameterConfig.kt 的 ID、来源和归还语义一致）
enum HomeParameterSource: String, Codable, CaseIterable, Hashable {
    case app, bms, controller
}

enum HomeParameterRegion: String, Codable, CaseIterable, Hashable {
    case top, vehicle, controller

    var title: String {
        switch self {
        case .top: return "顶部参数"
        case .vehicle: return "车辆 / BMS 参数"
        case .controller: return "控制器参数"
        }
    }

    func allows(_ source: HomeParameterSource) -> Bool {
        switch self {
        case .top: return true
        case .vehicle: return source != .controller
        case .controller: return source == .controller
        }
    }
}

struct HomeParameterMetricDefinition: Equatable, Identifiable {
    let id: String
    let source: HomeParameterSource
    let title: String
    let unit: String

    static let all: [Self] = [
        Self(id: "app_gps_speed", source: .app, title: "APP · GPS 速度", unit: "km/h"),
        Self(id: "app_range", source: .app, title: "APP · 综合剩余续航", unit: "km"),
        Self(id: "app_average_speed", source: .app, title: "APP · 综合平均速度", unit: "km/h"),
        Self(id: "app_consumption", source: .app, title: "APP · 电耗", unit: "Wh/km"),
        Self(id: "app_reference_consumption", source: .app, title: "APP · 参考电耗", unit: "km/Ah"),
        Self(id: "bms_remaining", source: .bms, title: "BMS · 剩余电量", unit: "Ah"),
        Self(id: "bms_soc", source: .bms, title: "BMS · 电量", unit: "%"),
        Self(id: "bms_power", source: .bms, title: "BMS · 功率", unit: "W"),
        Self(id: "bms_current", source: .bms, title: "BMS · 电流", unit: "A"),
        Self(id: "bms_voltage", source: .bms, title: "BMS · 总电压", unit: "V"),
        Self(id: "bms_diff", source: .bms, title: "BMS · 电芯压差", unit: "mV"),
        Self(id: "bms_temperature", source: .bms, title: "BMS · 最高温度", unit: "℃"),
        Self(id: "bms_mos_temperature", source: .bms, title: "BMS · MOS 温度", unit: "℃"),
        Self(id: "bms_cell_count", source: .bms, title: "BMS · 电芯数量", unit: ""),
        Self(id: "bms_rssi", source: .bms, title: "BMS · 信号强度", unit: "dBm"),
        Self(id: "bms_status", source: .bms, title: "BMS · 状态", unit: ""),
        Self(id: "bms_mos_status", source: .bms, title: "BMS · MOS 状态", unit: ""),
        Self(id: "bms_soh", source: .bms, title: "BMS · SOH", unit: "%"),
        Self(id: "bms_runtime", source: .bms, title: "BMS · 运行时间", unit: ""),
        Self(id: "bms_capacity", source: .bms, title: "BMS · 总容量", unit: "Ah"),
        Self(id: "bms_balancer_temperature", source: .bms, title: "BMS · 均衡温度", unit: "℃"),
        Self(id: "controller_voltage", source: .controller, title: "控制器 · 电压", unit: "V"),
        Self(id: "controller_bus_current", source: .controller, title: "控制器 · 母线电流", unit: "A"),
        Self(id: "controller_rpm", source: .controller, title: "控制器 · 转速", unit: "RPM"),
        Self(id: "controller_temperature", source: .controller, title: "控制器 · 温度", unit: "℃"),
        Self(id: "controller_motor_temperature", source: .controller, title: "控制器 · 电机温度", unit: "℃"),
        Self(id: "controller_phase_current", source: .controller, title: "控制器 · 相峰值电流", unit: "A"),
        Self(id: "controller_run_state", source: .controller, title: "控制器 · 运行状态", unit: ""),
        Self(id: "controller_fault", source: .controller, title: "控制器 · 故障摘要", unit: ""),
        Self(id: "controller_throttle_voltage", source: .controller, title: "控制器 · 转把电压", unit: "V"),
        Self(id: "controller_gear", source: .controller, title: "控制器 · 档位", unit: ""),
        Self(id: "controller_state_bits", source: .controller, title: "控制器 · 状态位图", unit: ""),
        Self(id: "controller_port_bits", source: .controller, title: "控制器 · 端口状态位图", unit: ""),
        Self(id: "controller_given_iq", source: .controller, title: "控制器 · 给定 Iq", unit: "A"),
        Self(id: "controller_feedback_iq", source: .controller, title: "控制器 · 反馈 Iq", unit: "A"),
        Self(id: "controller_given_id", source: .controller, title: "控制器 · 给定 Id", unit: "A"),
        Self(id: "controller_field_weakening", source: .controller, title: "控制器 · 弱磁电流", unit: "A"),
        Self(id: "controller_history_fault_bits", source: .controller, title: "控制器 · 历史故障位图", unit: ""),
        Self(id: "controller_linear_brake_voltage", source: .controller, title: "控制器 · 线性刹车电压", unit: "V")
    ]

    static func definition(for id: String) -> Self? { all.first { $0.id == id } }
}

struct HomeParameterSlotDefinition: Equatable, Identifiable {
    let id: String
    let region: HomeParameterRegion
    let defaultMetricId: String

    static let all: [Self] = [
        Self(id: "top_speed", region: .top, defaultMetricId: "app_gps_speed"),
        Self(id: "top_range", region: .top, defaultMetricId: "app_range"),
        Self(id: "top_remaining", region: .top, defaultMetricId: "bms_remaining"),
        Self(id: "top_soc", region: .top, defaultMetricId: "bms_soc"),
        Self(id: "top_power", region: .top, defaultMetricId: "bms_power"),
        Self(id: "top_current", region: .top, defaultMetricId: "bms_current"),
        Self(id: "vehicle_voltage", region: .vehicle, defaultMetricId: "bms_voltage"),
        Self(id: "vehicle_diff", region: .vehicle, defaultMetricId: "bms_diff"),
        Self(id: "vehicle_average_speed", region: .vehicle, defaultMetricId: "app_average_speed"),
        Self(id: "vehicle_consumption", region: .vehicle, defaultMetricId: "app_consumption"),
        Self(id: "vehicle_reference_consumption", region: .vehicle, defaultMetricId: "app_reference_consumption"),
        Self(id: "vehicle_temperature", region: .vehicle, defaultMetricId: "bms_temperature"),
        Self(id: "vehicle_mos_temperature", region: .vehicle, defaultMetricId: "bms_mos_temperature"),
        Self(id: "vehicle_cell_count", region: .vehicle, defaultMetricId: "bms_cell_count"),
        Self(id: "vehicle_rssi", region: .vehicle, defaultMetricId: "bms_rssi"),
        Self(id: "vehicle_status", region: .vehicle, defaultMetricId: "bms_status"),
        Self(id: "vehicle_mos_status", region: .vehicle, defaultMetricId: "bms_mos_status"),
        Self(id: "vehicle_soh", region: .vehicle, defaultMetricId: "bms_soh"),
        Self(id: "vehicle_runtime", region: .vehicle, defaultMetricId: "bms_runtime"),
        Self(id: "controller_voltage", region: .controller, defaultMetricId: "controller_voltage"),
        Self(id: "controller_bus_current", region: .controller, defaultMetricId: "controller_bus_current"),
        Self(id: "controller_rpm", region: .controller, defaultMetricId: "controller_rpm"),
        Self(id: "controller_temperature", region: .controller, defaultMetricId: "controller_temperature"),
        Self(id: "controller_motor_temperature", region: .controller, defaultMetricId: "controller_motor_temperature"),
        Self(id: "controller_phase_current", region: .controller, defaultMetricId: "controller_phase_current"),
        Self(id: "controller_run_state", region: .controller, defaultMetricId: "controller_run_state"),
        Self(id: "controller_fault", region: .controller, defaultMetricId: "controller_fault")
    ]

    static let heroIDs = ["top_speed", "top_range"]
    static let gridIDs = ["top_remaining", "top_soc", "top_power", "top_current"]

    static func definition(for id: String) -> Self? {
        if let fixed = all.first(where: { $0.id == id }) { return fixed }
        for region in [HomeParameterRegion.vehicle, .controller] {
            let prefix = "\(region.rawValue)_extra_"
            guard id.hasPrefix(prefix) else { continue }
            let suffix = String(id.dropFirst(prefix.count))
            guard suffix.range(of: "\\A[a-z][a-z0-9_]*\\z", options: .regularExpression) != nil else { return nil }
            return Self(id: id, region: region, defaultMetricId: "")
        }
        return nil
    }
}

struct HomeParameterAssignment: Codable, Equatable, Identifiable {
    let slotId: String
    var metricId: String
    var id: String { slotId }
}

enum HomeParameterCandidateKind: Equatable {
    case current, directReplace, swap, rehomeReplace, disabled

    var title: String {
        switch self {
        case .current: return "当前指标"
        case .directReplace: return "替换"
        case .swap: return "交换"
        case .rehomeReplace: return "接管并归还"
        case .disabled: return "不可选"
        }
    }
}

struct HomeParameterCandidate {
    let kind: HomeParameterCandidateKind
    let result: HomeParameterConfig?
    var disabledReason: String? = nil
    var occupiedSlotId: String? = nil
}

extension HomeParameterConfig {
    func hasValidAssignments() -> Bool {
        guard let assignments, !assignments.isEmpty else { return false }
        let slots = assignments.map(\.slotId)
        let metrics = assignments.map(\.metricId)
        guard Set(slots).count == slots.count, Set(metrics).count == metrics.count else { return false }
        let top = assignments.filter { HomeParameterSlotDefinition.definition(for: $0.slotId)?.region == .top }.map(\.slotId)
        guard Set(top) == Set(HomeParameterSlotDefinition.all.filter { $0.region == .top }.map(\.id)) else { return false }
        return assignments.allSatisfy {
            guard let slot = HomeParameterSlotDefinition.definition(for: $0.slotId),
                  let metric = HomeParameterMetricDefinition.definition(for: $0.metricId) else { return false }
            return slot.region.allows(metric.source)
        }
    }

    func assignments(in region: HomeParameterRegion) -> [HomeParameterAssignment] {
        (assignments ?? []).filter { HomeParameterSlotDefinition.definition(for: $0.slotId)?.region == region }
    }

    func metricId(for slotId: String) -> String? {
        assignments?.first { $0.slotId == slotId }?.metricId
    }

    func isCustomized(_ slotId: String) -> Bool {
        guard let slot = HomeParameterSlotDefinition.all.first(where: { $0.id == slotId }) else { return true }
        return metricId(for: slotId) != slot.defaultMetricId
    }

    func normalized() -> Self {
        guard let assignments else { return self }
        let fixed = HomeParameterSlotDefinition.all.compactMap { slot in assignments.first { $0.slotId == slot.id } }
        // 按安卓：固定槽定义顺序 + 原追加顺序的动态底槽。
        let fixedIDs = Set(HomeParameterSlotDefinition.all.map(\.id))
        return Self(cards: cards, assignments: fixed + assignments.filter { !fixedIDs.contains($0.slotId) })
    }

    /// 唯一候选入口：编辑器展示与实际执行共享同一判定。
    func candidate(slotId: String, metricId: String) -> HomeParameterCandidate {
        func disabled(_ reason: String) -> HomeParameterCandidate {
            HomeParameterCandidate(kind: .disabled, result: nil, disabledReason: reason)
        }
        guard isValid(), let assignments else { return disabled("当前配置无效，无法修改") }
        guard let slot = HomeParameterSlotDefinition.definition(for: slotId),
              let oldMetricId = self.metricId(for: slotId) else { return disabled("未知参数框或缺少分配") }
        guard let metric = HomeParameterMetricDefinition.definition(for: metricId) else { return disabled("未知指标") }
        guard slot.region.allows(metric.source) else {
            return disabled(slot.region == .controller ? "控制器区只能显示控制器指标" : "车辆区只能显示 APP 或 BMS 指标")
        }
        if oldMetricId == metricId { return HomeParameterCandidate(kind: .current, result: self) }
        let occupied = assignments.first { $0.metricId == metricId }
        var next = assignments
        var kind: HomeParameterCandidateKind = .directReplace
        if slot.region != .top {
            if let occupied {
                guard let other = HomeParameterSlotDefinition.definition(for: occupied.slotId),
                      let old = HomeParameterMetricDefinition.definition(for: oldMetricId),
                      other.region.allows(old.source) else { return disabled("底部参数只能在合法来源区域内调整") }
                next = next.map { $0.slotId == occupied.slotId ? HomeParameterAssignment(slotId: $0.slotId, metricId: oldMetricId) : $0 }
                kind = .swap
            }
            next = next.map { $0.slotId == slotId ? HomeParameterAssignment(slotId: slotId, metricId: metricId) : $0 }
        } else if let occupied, HomeParameterSlotDefinition.definition(for: occupied.slotId)?.region == .top {
            next = next.map {
                if $0.slotId == slotId { return HomeParameterAssignment(slotId: slotId, metricId: metricId) }
                if $0.slotId == occupied.slotId { return HomeParameterAssignment(slotId: occupied.slotId, metricId: oldMetricId) }
                return $0
            }
            kind = .swap
        } else {
            // 顶部接管底部：删除被接管框，不交换；旧顶部指标按来源归还。
            next = next.filter { $0.slotId != occupied?.slotId }.map {
                $0.slotId == slotId ? HomeParameterAssignment(slotId: slotId, metricId: metricId) : $0
            }
            guard let old = HomeParameterMetricDefinition.definition(for: oldMetricId) else { return disabled("未知旧指标") }
            let region: HomeParameterRegion = old.source == .controller ? .controller : .vehicle
            let base = "\(region.rawValue)_extra_\(oldMetricId)"
            let existing = Set(next.map(\.slotId))
            var returnedId = base
            var suffix = 2
            while existing.contains(returnedId) { returnedId = "\(base)_\(suffix)"; suffix += 1 }
            next.append(HomeParameterAssignment(slotId: returnedId, metricId: oldMetricId))
            kind = occupied == nil ? .directReplace : .rehomeReplace
        }
        var result = Self(cards: cards, assignments: next)
        guard result.isValid() else { return disabled("替换后配置无效") }
        // 安卓仅顶部动态归还规范顺序，其余交换保留原分配顺序。
        if slot.region == .top && kind != .swap { result = result.normalized() }
        return HomeParameterCandidate(kind: kind, result: result, occupiedSlotId: occupied?.slotId)
    }
}

extension HomeParameterEditSession {
    func select(slotId: String, metricId: String) -> Self {
        guard let result = draft.candidate(slotId: slotId, metricId: metricId).result else { return self }
        return Self(baseline: baseline, draft: result)
    }
}

/// 安卓横竖屏及三列底部规则；布局只读取同一份分配，不复制指标。
enum HomeParameterLayout {
    static func isPortrait(width: Double, height: Double) -> Bool { width < height }

    static func span(_ assignment: HomeParameterAssignment, in region: HomeParameterRegion) -> Int {
        region == .controller && assignment.metricId == "controller_fault" ? 2 : 1
    }

    static func rows(_ assignments: [HomeParameterAssignment], in region: HomeParameterRegion) -> [[HomeParameterAssignment]] {
        var rows: [[HomeParameterAssignment]] = []
        var row: [HomeParameterAssignment] = []
        var used = 0
        for assignment in assignments {
            let width = span(assignment, in: region)
            if used + width > 3 { rows.append(row); row = []; used = 0 }
            row.append(assignment)
            used += width
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}
