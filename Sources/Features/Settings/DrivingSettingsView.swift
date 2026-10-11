import Foundation
import SwiftUI
import ANTuRideDomain

extension DrivingSettings {
    var preferredColorScheme: ColorScheme? {
        switch appThemeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 主线程接入点：在 App 根部持有同一个 store，观察 $settings 或使用页面 onSave。
/// UserDefaults key: driving_settings_v1（JSON Data）；仅写此键，不碰服务保存的外设 UUID。
/// 首次接入应读取 settings；每次保存后再由主线程将偏好应用到各消费端。
/// 本类/页面不执行蓝牙连接、查询、硬件写入、主题切换或续航算法配置。
@MainActor
final class DrivingSettingsStore: ObservableObject {
    static let key = "driving_settings_v1"

    @Published private(set) var settings: DrivingSettings = .defaults
    @Published private(set) var notice: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// 外部修改同一 key 后由主线程显式 reload；不会自动观察其他 store 实例。
    /// 异常存储保留原值，等待用户显式保存或恢复默认，不在读取时覆盖。
    func reload() {
        guard let stored = defaults.object(forKey: Self.key) else {
            settings = .defaults
            notice = nil
            return
        }
        guard let data = stored as? Data,
              let decoded = try? JSONDecoder().decode(DrivingSettings.self, from: data) else {
            settings = .defaults
            notice = "本地设置损坏或格式不兼容，当前显示默认值；原存储尚未覆盖。"
            return
        }
        settings = decoded.normalized()
        notice = settings == decoded ? nil : "本地设置含越界值，当前显示规范化值；保存后才覆盖原存储。"
    }

    /// 非法设置抛错且不写入；仅发布已校验、已写入 UserDefaults 的偏好快照。
    /// UserDefaults 并非同步落盘保证，也不代表消费端已应用这些偏好。
    func save(_ candidate: DrivingSettings) throws {
        try candidate.validate()
        let saved = candidate.normalized()
        let data = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: Self.key)
        settings = saved
        notice = "已保存到本机。主题、BMS 查询周期和续航配置由 App 消费；电池/控制器自动连接开关在蓝牙设备页设置，保存本身不触发连接。"
    }

    /// 驾驶页只覆盖驾驶与显示偏好；旧草稿不能回写续航页后来保存的窗口/刷新。
    /// 先校验完整候选值，非法输入不写入，也不发布 settings/notice。
    func saveDrivingPreferences(_ candidate: DrivingSettings) throws {
        try candidate.validate()
        var saved = candidate
        saved.rangeWindowMinutes = settings.rangeWindowMinutes
        saved.rangeRefreshSeconds = settings.rangeRefreshSeconds
        saved.bmsAutoConnectEnabled = settings.bmsAutoConnectEnabled
        saved.controllerAutoConnectEnabled = settings.controllerAutoConnectEnabled
        try save(saved)
    }

    /// 蓝牙页仅修改连接意愿；基于最新快照，不覆盖其他页面已保存的字段。
    func saveBluetoothPreferences(bmsEnabled: Bool, controllerEnabled: Bool) throws {
        var candidate = settings
        candidate.bmsAutoConnectEnabled = bmsEnabled
        candidate.controllerAutoConnectEnabled = controllerEnabled
        try save(candidate)
    }

    /// 续航页只覆盖两个全局周期字段，始终基于最新快照保留驾驶与显示偏好。
    func saveRangePreferences(windowMinutes: Int, refreshSeconds: Int) throws {
        var candidate = settings
        candidate.rangeWindowMinutes = windowMinutes
        candidate.rangeRefreshSeconds = refreshSeconds
        try save(candidate)
    }

    /// 局部恢复不改变续航窗口/刷新，也不触碰首页布局、外设 UUID、设备容量或历史。
    func restoreDrivingPreferencesDefaults() throws {
        try saveDrivingPreferences(.defaults)
    }

    /// 保留全量恢复契约，供需要重置所有 DrivingSettings 的调用方使用。
    func restoreDefaults() throws { try save(.defaults) }
}

/// 驾驶与显示偏好的草稿页面。未保存的输入不写 UserDefaults；返回页面不会隐式保存。
/// 接入示例（主线程）：DrivingSettingsView(store: store) { settings in /* 应用偏好 */ }
/// App/Root 已消费主题和 BMS 查询周期；连接策略在蓝牙设备页编辑，续航周期在续航设置编辑。
/// 字号/描述/功率图/阈值/探头选择由 Dashboard 单独消费，连接开关在蓝牙设备页编辑。
/// 控制器采样周期不属于本页。
/// 横竖屏锁需要 UIApplication/scene 方向策略，故不提供伪有效的开关。
@MainActor
struct DrivingSettingsView: View {
    @StateObject private var store: DrivingSettingsStore
    @State private var draft: DrivingSettings
    @State private var numericText: [String: String]
    @State private var validationErrors: [String] = []
    @State private var confirmingReset = false
    @FocusState private var focusedField: String?
    private let onSave: (DrivingSettings) -> Void

    init(store: DrivingSettingsStore, onSave: @escaping (DrivingSettings) -> Void = { _ in }) {
        _store = StateObject(wrappedValue: store)
        _draft = State(initialValue: store.settings)
        _numericText = State(initialValue: Self.textValues(for: store.settings))
        self.onSave = onSave
    }

    init(defaults: UserDefaults = .standard, onSave: @escaping (DrivingSettings) -> Void = { _ in }) {
        self.init(store: DrivingSettingsStore(defaults: defaults), onSave: onSave)
    }

    var body: some View {
        Form {
            Section {
                Text("本页管理驾驶与显示偏好，不写 BMS 或控制器硬件配置。App 已接入主题、BMS 查询周期；自动连接请在蓝牙设备中设置，续航窗口和刷新请在续航设置中编辑。保存不代表设备连接成功。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Self.cadenceFields) { numericRow($0) }
            } header: {
                Text("BMS 查询采样")
            } footer: {
                Text("BMS 查询周期 100–60000 ms。控制器独立查询周期不在此修改；续航窗口和刷新仅在续航设置中编辑。")
            }
            Section {
                Picker("主题", selection: $draft.appThemeMode) {
                    Text("跟随系统").tag(DrivingSettings.ThemeMode.system)
                    Text("浅色").tag(DrivingSettings.ThemeMode.light)
                    Text("深色").tag(DrivingSettings.ThemeMode.dark)
                }
                ForEach(Self.scaleFields) { numericRow($0) }
                Toggle("首页显示文字描述", isOn: $draft.showTextDescriptions)
                Picker("默认功率图", selection: $draft.defaultPowerDisplayMode) {
                    Text("功率条").tag(DrivingSettings.PowerDisplayMode.powerBar)
                    Text("实时曲线").tag(DrivingSettings.PowerDisplayMode.curve)
                }
                TextField("温度来源", text: $draft.temperatureSource)
                    .focused($focusedField, equals: "temperatureSource")
                    .accessibilityIdentifier("driving.temperatureSource")
            } header: {
                Text("显示偏好")
            } footer: {
                Text("字号比例 0.5–2.0，仅表示数值大小。温度来源默认“自动”，也可输入探头序号（从 1 开始）；实际探头选择与越界回退需遥测消费端接入。")
            }
            Section {
                ForEach(Self.powerFields) { numericRow($0) }
            } header: {
                Text("功率条阈值")
            } footer: {
                Text("功率基数 ≥ 1 W；黄色/红色起点为基数比例 0–1，黄色 ≤ 红色。这里只保存显示阈值，不是功率限制或保护参数。")
            }
            Section {
                ForEach(Self.socFields) { numericRow($0) }
            } header: {
                Text("SOC 颜色阈值")
            } footer: {
                Text("范围 0–100%，红色上限 ≤ 黄色上限。")
            }
            Section {
                ForEach(Self.temperatureFields) { numericRow($0) }
            } header: {
                Text("温度颜色阈值")
            } footer: {
                Text("范围 -50–150 °C，绿色上限 ≤ 黄色上限；不是 BMS 温度保护设置。")
            }
            Section {
                ForEach(Self.differenceFields) { numericRow($0) }
            } header: {
                Text("压差颜色阈值")
            } footer: {
                Text("压差为非负 mV，绿色上限 ≤ 黄色上限。安卓未设置额外上限。")
            }
            Section {
                ForEach(Self.speedFields) { numericRow($0) }
            } header: {
                Text("标题速度颜色阈值")
            } footer: {
                Text("满格 1–300 km/h；0 ≤ 中速 ≤ 高速 ≤ 满格。不是车辆限速。")
            }
            Section {
                ForEach(Array(validationErrors.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption).foregroundStyle(.red)
                }
                if let notice = store.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Button("保存本机驾驶与显示设置") { saveDraft() }
                    .accessibilityIdentifier("driving.save")
                Button("撤销未保存修改") { reloadDraft() }
                Button("恢复驾驶与显示默认值", role: .destructive) {
                    focusedField = nil
                    confirmingReset = true
                }
                .accessibilityIdentifier("driving.restoreDefaults")
            } footer: {
                Text("恢复默认仅重置本页驾驶与显示偏好，保留蓝牙自动连接开关、续航周期、首页布局、外设 UUID、设备容量、行程和日志。不控制全局横竖屏。")
            }
        }
        .navigationTitle("驾驶与显示设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.reload()
            reloadDraft()
        }
        .confirmationDialog("恢复驾驶与显示默认值？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("恢复并保存默认值", role: .destructive) {
                do {
                    try store.restoreDrivingPreferencesDefaults()
                    reloadDraft()
                    onSave(store.settings)
                } catch {
                    validationErrors = [error.localizedDescription]
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅覆盖本页驾驶与显示偏好和当前草稿，保留两个自动连接开关和续航窗口/刷新、首页布局、外设 UUID、设备容量、行程和日志。本页不会执行连接。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
    }

    private func numericRow(_ field: NumericField) -> some View {
        HStack {
            Text(field.title)
            Spacer()
            TextField(field.title, text: Binding(
                get: { numericText[field.id] ?? "" },
                set: { numericText[field.id] = $0 }
            ))
            .keyboardType(field.isInteger ? .numberPad : .numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 75, maxWidth: 130)
            .focused($focusedField, equals: field.id)
            .accessibilityIdentifier("driving.\(field.id)")
        }
    }

    private func reloadDraft() {
        focusedField = nil
        draft = store.settings
        numericText = Self.textValues(for: draft)
        validationErrors = []
    }

    private func saveDraft() {
        focusedField = nil
        var candidate = draft
        var errors: [String] = []
        for field in Self.allFields {
            if let error = field.apply(numericText[field.id] ?? "", to: &candidate) {
                errors.append(error)
            }
        }
        // 不因某个输入解析失败而用草稿旧值保存。
        guard errors.isEmpty else {
            validationErrors = errors
            return
        }
        do {
            try store.saveDrivingPreferences(candidate)
            reloadDraft()
            onSave(store.settings)
        } catch let error as DrivingSettings.ValidationError {
            validationErrors = error.messages
        } catch {
            validationErrors = [error.localizedDescription]
        }
    }

    private static func textValues(for settings: DrivingSettings) -> [String: String] {
        Dictionary(uniqueKeysWithValues: allFields.map { ($0.id, $0.text(in: settings)) })
    }

    /// 输入保留为文本草稿，使空值、负温度、小数及非法输入可见，保存时再严格解析。
    private struct NumericField: Identifiable {
        enum ValuePath {
            case integer(WritableKeyPath<DrivingSettings, Int>)
            case decimal(WritableKeyPath<DrivingSettings, Double>)
        }
        let id: String
        let title: String
        let path: ValuePath
        var isInteger: Bool {
            if case .integer = path { return true }
            return false
        }
        func text(in settings: DrivingSettings) -> String {
            switch path {
            case .integer(let key): return String(settings[keyPath: key])
            case .decimal(let key): return String(settings[keyPath: key])
            }
        }
        func apply(_ text: String, to settings: inout DrivingSettings) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch path {
            case .integer(let key):
                guard let value = Int(trimmed) else { return "\(title)必须是整数。" }
                settings[keyPath: key] = value
            case .decimal(let key):
                // 支持点号及小数逗号，不接受分组符号或非有限数值。
                guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
                    return "\(title)必须是有限数字（不使用千位分隔符）。"
                }
                settings[keyPath: key] = value
            }
            return nil
        }
    }

    private static let cadenceFields: [NumericField] = [
        .init(id: "bluetoothRefreshIntervalMs", title: "BMS 查询（ms）", path: .integer(\DrivingSettings.bluetoothRefreshIntervalMs))
    ]
    private static let scaleFields: [NumericField] = [
        .init(id: "valueScale", title: "数值字号比例", path: .decimal(\DrivingSettings.valueScale))
    ]
    private static let powerFields: [NumericField] = [
        .init(id: "dischargeBaseW", title: "放电基数（W）", path: .decimal(\DrivingSettings.dischargeBaseW)),
        .init(id: "chargeBaseW", title: "充电基数（W）", path: .decimal(\DrivingSettings.chargeBaseW)),
        .init(id: "powerYellowStart", title: "黄色起点（0–1）", path: .decimal(\DrivingSettings.powerYellowStart)),
        .init(id: "powerRedStart", title: "红色起点（0–1）", path: .decimal(\DrivingSettings.powerRedStart))
    ]
    private static let socFields: [NumericField] = [
        .init(id: "socRedUpperPercent", title: "红色上限（%）", path: .decimal(\DrivingSettings.socRedUpperPercent)),
        .init(id: "socYellowUpperPercent", title: "黄色上限（%）", path: .decimal(\DrivingSettings.socYellowUpperPercent))
    ]
    private static let temperatureFields: [NumericField] = [
        .init(id: "tempGreenUpperC", title: "绿色上限（°C）", path: .decimal(\DrivingSettings.tempGreenUpperC)),
        .init(id: "tempYellowUpperC", title: "黄色上限（°C）", path: .decimal(\DrivingSettings.tempYellowUpperC))
    ]
    private static let differenceFields: [NumericField] = [
        .init(id: "diffGreenUpperMv", title: "绿色上限（mV）", path: .decimal(\DrivingSettings.diffGreenUpperMv)),
        .init(id: "diffYellowUpperMv", title: "黄色上限（mV）", path: .decimal(\DrivingSettings.diffYellowUpperMv))
    ]
    private static let speedFields: [NumericField] = [
        .init(id: "powerHeaderSpeedBaseKmh", title: "满格速度（km/h）", path: .decimal(\DrivingSettings.powerHeaderSpeedBaseKmh)),
        .init(id: "powerHeaderSpeedMidKmh", title: "中速阈值（km/h）", path: .decimal(\DrivingSettings.powerHeaderSpeedMidKmh)),
        .init(id: "powerHeaderSpeedHighKmh", title: "高速阈值（km/h）", path: .decimal(\DrivingSettings.powerHeaderSpeedHighKmh))
    ]
    private static var allFields: [NumericField] {
        cadenceFields + scaleFields + powerFields + socFields + temperatureFields + differenceFields + speedFields
    }
}
