import Combine
import CoreBluetooth
import Foundation
import ANTuRideDomain

/// 一次启动机会：首次 poweredOn 即消耗（包含关闭策略/无记忆 UUID/已有手动会话）。
/// 手动扫描、连接或断开都结束本次启动机会，偏好后续开关不触发即时连接。
struct BmsStartupConnectionPolicy {
    private(set) var consumed = false
    mutating func suppressForRun() { consumed = true }
    mutating func consumeTarget(poweredOn: Bool, enabled: Bool, rememberedID: UUID?, hasActiveSession: Bool) -> UUID? {
        guard poweredOn, !consumed else { return nil }
        consumed = true
        return enabled && !hasActiveSession ? rememberedID : nil
    }
}

/// ANT BMS 蓝牙链路：
/// - 扫描列表由用户选择；启动仅尝试服务独立记忆的 UUID 一次。
/// - Notify 开启后才允许周期查询。
/// - 意外断开时清理会话后自动重试同一外设一次，不重复创建会话。
@MainActor
public final class BmsBluetoothService: NSObject, ObservableObject {
    public static let bmsServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    public static let bmsCharacteristicUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    /// 周期查询间隔，与 Android 端节奏一致。
    public static let queryInterval: TimeInterval = 1.0
    static let rememberedDeviceDefaultsKey = "com.zjsf.anturide.bms.lastPeripheralUUID"
    @Published public private(set) var effectiveQueryInterval: TimeInterval = BmsBluetoothService.queryInterval
    /// 默认名称过滤关键字（大小写不敏感）：`ant` 对应 ANT BMS 电池保护板，
    /// `apt` 对应 APT 电机控制器；兼容不广播 FFE0 服务的固件。
    static let nameKeywords = ["ant", "apt"]
    /// 设备名过滤开关的持久化键。
    private static let keywordFilterDefaultsKey = "com.zjsf.anturide.deviceKeywordFilterEnabled"

    public enum State: Equatable {
        case idle
        case poweredOff
        case scanning
        case connecting
        case discovering
        case ready
        case reconnecting
        case disconnected
    }

    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published public private(set) var connectedDeviceName: String?
    /// CoreBluetooth 外设身份；不使用可重名的广播名称隔离设置。
    @Published public private(set) var connectedDeviceID: UUID?
    @Published public private(set) var rssi: Int?
    @Published public private(set) var rssiReceivedAt: Date?
    private var lastRSSIRequestAt: Date?
    @Published public private(set) var latestSnapshot: BmsSnapshot?
    @Published public private(set) var snapshotHistory: [BmsSnapshot] = []
    @Published public private(set) var lastError: String?
    /// 是否按设备名关键字过滤扫描结果。默认开启；关闭后列出附近全部蓝牙设备。
    @Published public private(set) var isKeywordFilterEnabled: Bool = true

    private let central: CBCentralManager?
    private let defaults: UserDefaults
    private var startupAutoConnectEnabled: Bool
    private var startupPolicy = BmsStartupConnectionPolicy()
    private var retiringPeripheralIDs = Set<UUID>()
    private var pendingConnectionID: UUID?
    private var sessionGeneration: UInt64 = 0
    private var queryGeneration: UInt64 = 0
    private var hasRetriedUnexpectedDisconnect = false
    private let assembler = BmsFrameAssembler()
    private let maximumHistoryCount = 120

    private var peripheral: CBPeripheral?
    private var peripheralCallbacks: BmsPeripheralCallbacks?
    private var characteristic: CBCharacteristic?
    private var queryTimer: Timer?
    private var isUserInitiatedDisconnect = false
    private var deviceSummaries: [UUID: DiscoveredDevice] = [:]

    public override convenience init() {
        self.init(defaults: .standard, startupAutoConnectEnabled: true, queryIntervalMs: 1000)
    }

    /// 配置在 delegate 安装前确定，避免首次 poweredOn 先读取默认开启再读用户关闭偏好。
    /// createsBluetoothManager=false 仅供无硬件单元测试，不会创建 manager 或请求权限。
    public init(defaults: UserDefaults = .standard, startupAutoConnectEnabled: Bool,
                queryIntervalMs: Int, createsBluetoothManager: Bool = true) {
        self.defaults = defaults
        self.startupAutoConnectEnabled = startupAutoConnectEnabled
        central = createsBluetoothManager ? CBCentralManager(delegate: nil, queue: .main) : nil
        super.init()
        effectiveQueryInterval = Self.normalizedQueryInterval(milliseconds: queryIntervalMs)
        isKeywordFilterEnabled = defaults.object(forKey: Self.keywordFilterDefaultsKey) as? Bool ?? true
        central?.delegate = self
    }

    public func applyDrivingSettings(_ settings: DrivingSettings) {
        startupAutoConnectEnabled = settings.bmsAutoConnectEnabled
        let interval = Self.normalizedQueryInterval(milliseconds: settings.bluetoothRefreshIntervalMs)
        guard effectiveQueryInterval != interval else { return }
        effectiveQueryInterval = interval
        if state == .ready { startQueryTimer() }
    }

    static func normalizedQueryInterval(milliseconds: Int) -> TimeInterval {
        let bounds = DrivingSettings.bluetoothRefreshIntervalMsBounds
        return TimeInterval(min(max(milliseconds, bounds.lowerBound), bounds.upperBound)) / 1000
    }

    private func attemptStartupConnection() {
        let rememberedID = defaults.string(forKey: Self.rememberedDeviceDefaultsKey).flatMap(UUID.init(uuidString:))
        guard let id = startupPolicy.consumeTarget(poweredOn: central?.state == .poweredOn,
                                                   enabled: startupAutoConnectEnabled,
                                                   rememberedID: rememberedID,
                                                   hasActiveSession: peripheral != nil || pendingConnectionID != nil) else { return }
        requestConnection(to: id)
    }

    // MARK: - 扫描

    public func startScan() {
        guard let central, central.state == .poweredOn else {
            state = .poweredOff
            lastError = "蓝牙未开启"
            AppLog.ble.warning("启动扫描被拒绝：蓝牙未开启 (central.state=\(self.central?.state.rawValue ?? -1))")
            return
        }
        startupPolicy.suppressForRun()
        if peripheral != nil || pendingConnectionID != nil {
            pendingConnectionID = nil
            isUserInitiatedDisconnect = true
            retireCurrentPeripheral()
        }
        deviceSummaries.removeAll()
        discoveredDevices = []
        state = .scanning
        AppLog.ble.notice("开始扫描 (名称过滤=\(isKeywordFilterEnabled)，关键字=\(Self.nameKeywords))")
        beginScan()
    }

    /// 开启一次扫描。不按服务过滤扫描：部分 ANT BMS 固件不广播 FFE0，
    /// 由 didDiscover 回调按广播服务与名称关键字过滤。
    private func beginScan() {
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// 切换设备名过滤开关并持久化。过滤只在发现阶段生效，
    /// 因此需要清空结果并在扫描中时重启扫描才能反映新条件。
    public func setKeywordFilterEnabled(_ enabled: Bool) {
        guard enabled != isKeywordFilterEnabled else { return }
        isKeywordFilterEnabled = enabled
        defaults.set(enabled, forKey: Self.keywordFilterDefaultsKey)
        AppLog.ble.info("名称过滤开关切换为 \(enabled)")
        deviceSummaries.removeAll()
        discoveredDevices = []
        guard let central, central.state == .poweredOn, state == .scanning else { return }
        central.stopScan()
        beginScan()
    }

    public func stopScan() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    // MARK: - 连接

    public func connect(to id: UUID) {
        startupPolicy.suppressForRun()
        requestConnection(to: id)
    }

    private func requestConnection(to id: UUID) {
        guard let central, central.state == .poweredOn else {
            lastError = "蓝牙未开启"
            return
        }
        guard central.retrievePeripherals(withIdentifiers: [id]).first != nil else {
            lastError = "设备已不可用，请重新扫描"
            return
        }
        if peripheral?.identifier == id, [.connecting, .discovering, .ready].contains(state) { return }
        stopScan()
        pendingConnectionID = id
        isUserInitiatedDisconnect = false
        hasRetriedUnexpectedDisconnect = false
        // 即使同一个 UUID 重新选择，也先等待旧连接的终止回调；禁止把旧 didDisconnect
        // 误认为新会话断开。换不同 UUID 可以立即启动，旧 UUID 的回调仍在 retirement 集合过滤。
        retireCurrentPeripheral()
        startPendingConnectionIfPossible()
    }

    private func retireCurrentPeripheral() {
        let previous = peripheral
        peripheral = nil
        previous?.delegate = nil
        teardownSession()
        if let previous {
            retiringPeripheralIDs.insert(previous.identifier)
            central?.cancelPeripheralConnection(previous)
        }
    }

    private func startPendingConnectionIfPossible() {
        guard let central, central.state == .poweredOn, !isUserInitiatedDisconnect,
              let id = pendingConnectionID, !retiringPeripheralIDs.contains(id) else { return }
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            pendingConnectionID = nil
            state = .disconnected
            lastError = "记忆的 BMS 已不可用，请重新扫描"
            return
        }
        pendingConnectionID = nil
        peripheral = target
        installPeripheralCallbacks(for: target)
        state = .connecting
        lastError = nil
        AppLog.ble.notice("发起连接：\(target.name ?? "未命名") id=\(id.uuidString)")
        central.connect(target, options: nil)
    }

    public func disconnect() {
        startupPolicy.suppressForRun()
        isUserInitiatedDisconnect = true
        pendingConnectionID = nil
        AppLog.ble.notice("用户主动断开：\(connectedDeviceName ?? "未知设备")")
        retireCurrentPeripheral()
        state = .disconnected
    }

    private func installPeripheralCallbacks(for peripheral: CBPeripheral) {
        let callbacks = BmsPeripheralCallbacks(owner: self, generation: sessionGeneration)
        peripheralCallbacks = callbacks
        peripheral.delegate = callbacks
    }

    private func failCurrentSession(_ message: String) {
        pendingConnectionID = nil
        retireCurrentPeripheral()
        state = .disconnected
        lastError = message
    }

    private func isCurrentSession(_ candidate: CBPeripheral) -> Bool {
        peripheral === candidate && !retiringPeripheralIDs.contains(candidate.identifier)
            && !isUserInitiatedDisconnect && central?.state == .poweredOn
    }

    private func teardownSession() {
        sessionGeneration &+= 1
        peripheral?.delegate = nil
        peripheralCallbacks = nil
        assembler.reset()
        connectedDeviceID = nil
        connectedDeviceName = nil
        latestSnapshot = nil
        rssi = nil
        rssiReceivedAt = nil
        lastRSSIRequestAt = nil
        snapshotHistory = []
        characteristic = nil
        stopQueryTimer()
    }

    // MARK: - 周期查询

    private func startQueryTimer() {
        stopQueryTimer()
        let generation = queryGeneration
        let timer = Timer(timeInterval: effectiveQueryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.queryGeneration == generation else { return }
                self.sendQueryIfReady()
            }
        }
        queryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sendQueryIfReady()
    }

    private func stopQueryTimer() {
        queryGeneration &+= 1
        queryTimer?.invalidate()
        queryTimer = nil
    }

    private func sendQueryIfReady() {
        guard state == .ready, let peripheral, isCurrentSession(peripheral),
              let characteristic, characteristic.isNotifying else { return }
        if lastRSSIRequestAt.map({ Date().timeIntervalSince($0) >= 5 }) ?? true {
            lastRSSIRequestAt = Date()
            peripheral.readRSSI()
        }
        if characteristic.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else {
                AppLog.ble.debug("跳过本次查询：canSendWriteWithoutResponse=false")
                return
            }
            peripheral.writeValue(AntProtocol.queryCommand, for: characteristic, type: .withoutResponse)
        } else if characteristic.properties.contains(.write) {
            peripheral.writeValue(AntProtocol.queryCommand, for: characteristic, type: .withResponse)
        } else {
            AppLog.ble.warning("特征 FFE1 不支持写入，无法发送周期查询")
        }
    }

    /// 将特征属性位转成可读文本，用于日志（排障时判断写入/通知能力）。
    static func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNoResponse") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "无" : parts.joined(separator: "+")
    }

    private func recordSnapshot(_ snapshot: BmsSnapshot) {
        latestSnapshot = snapshot
        snapshotHistory.append(snapshot)
        if snapshotHistory.count > maximumHistoryCount {
            snapshotHistory.removeFirst(snapshotHistory.count - maximumHistoryCount)
        }
    }

    private func isCandidate(advertisedServices: [CBUUID], name: String) -> Bool {
        if advertisedServices.contains(Self.bmsServiceUUID) { return true }
        guard isKeywordFilterEnabled else { return true }
        let lowered = name.lowercased()
        return Self.nameKeywords.contains { lowered.contains($0) }
    }
}

extension BmsBluetoothService: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central else { return }
            if central.state == .poweredOn {
                if self.state == .poweredOff {
                    self.state = self.peripheral == nil ? .idle : .disconnected
                }
                self.lastError = nil
                AppLog.ble.notice("蓝牙状态：已开启 (state=\(self.state))")
                self.attemptStartupConnection()
            } else {
                AppLog.ble.warning("蓝牙状态变更为 \(central.state.rawValue)（非 poweredOn），清理会话")
                self.peripheral?.delegate = nil
                self.peripheral = nil
                self.pendingConnectionID = nil
                self.retiringPeripheralIDs.removeAll()
                self.teardownSession()
                self.state = .poweredOff
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let resolvedName = localName ?? peripheral.name ?? "未命名设备"
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central, central.state == .poweredOn,
                  self.state == .scanning else { return }
            guard self.isCandidate(advertisedServices: advertisedServices, name: resolvedName) else {
                AppLog.ble.debug("过滤设备：\(resolvedName) (广播服务=\(advertisedServices.map(\.uuidString)))")
                return
            }
            let device = DiscoveredDevice(id: peripheral.identifier, name: resolvedName, rssi: RSSI.intValue)
            if self.deviceSummaries[device.id] == nil {
                AppLog.ble.info("发现候选设备：\(resolvedName) RSSI=\(RSSI.intValue) dBm id=\(peripheral.identifier.uuidString)")
            }
            self.deviceSummaries[device.id] = device
            self.discoveredDevices = self.deviceSummaries.values.sorted { $0.rssi > $1.rssi }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central, self.isCurrentSession(peripheral),
                  self.state == .connecting else { return }
            self.connectedDeviceID = peripheral.identifier
            self.state = .discovering
            self.connectedDeviceName = peripheral.name ?? self.deviceSummaries[peripheral.identifier]?.name
            AppLog.ble.notice("已连接外设：\(self.connectedDeviceName ?? "未命名")，开始发现服务 FFE0")
            peripheral.discoverServices([Self.bmsServiceUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central else { return }
            if self.retiringPeripheralIDs.remove(peripheral.identifier) != nil {
                self.startPendingConnectionIfPossible()
                return
            }
            guard self.isCurrentSession(peripheral), self.state == .connecting else { return }
            peripheral.delegate = nil
            self.peripheral = nil
            self.teardownSession()
            self.state = .disconnected
            self.lastError = error?.localizedDescription ?? "连接失败"
            AppLog.ble.error("连接失败：\(error?.localizedDescription ?? "未知原因")")
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central else { return }
            if self.retiringPeripheralIDs.remove(peripheral.identifier) != nil {
                self.startPendingConnectionIfPossible()
                return
            }
            guard self.isCurrentSession(peripheral),
                  [.connecting, .discovering, .ready].contains(self.state) else { return }
            self.teardownSession()
            guard !self.hasRetriedUnexpectedDisconnect else {
                peripheral.delegate = nil
                self.peripheral = nil
                self.state = .disconnected
                self.lastError = error?.localizedDescription ?? "BMS 再次断开，请手动重连"
                return
            }
            self.hasRetriedUnexpectedDisconnect = true
            self.state = .reconnecting
            self.lastError = error?.localizedDescription
            let generation = self.sessionGeneration
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.sessionGeneration == generation, self.state == .reconnecting,
                  self.isCurrentSession(peripheral) else { return }
            self.installPeripheralCallbacks(for: peripheral)
            self.state = .connecting
            central.connect(peripheral, options: nil)
        }
    }
}

extension BmsBluetoothService {
    fileprivate nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.sessionGeneration == generation, self.isCurrentSession(peripheral), self.state == .discovering else { return }
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.bmsServiceUUID }) else {
                let message = error?.localizedDescription ?? "未找到 BMS 服务 (FFE0)"
                AppLog.ble.error("未发现 BMS 服务 FFE0：\(error?.localizedDescription ?? "服务列表中无 FFE0")，已发现服务=\(peripheral.services?.map(\.uuid.uuidString) ?? [])")
                self.failCurrentSession(message)
                return
            }
            AppLog.ble.notice("发现服务 FFE0，开始发现特征 FFE1")
            peripheral.discoverCharacteristics([Self.bmsCharacteristicUUID], for: service)
        }
    }

    fileprivate nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.sessionGeneration == generation, self.isCurrentSession(peripheral), self.state == .discovering,
                  self.characteristic == nil, service.uuid == Self.bmsServiceUUID,
                  peripheral.services?.contains(where: { $0 === service }) == true else { return }
            guard error == nil,
                  let characteristic = service.characteristics?.first(where: { $0.uuid == Self.bmsCharacteristicUUID }) else {
                let message = error?.localizedDescription ?? "未找到 BMS 特征 (FFE1)"
                AppLog.ble.error("未发现 BMS 特征 FFE1：\(error?.localizedDescription ?? "特征列表中无 FFE1")，已发现特征=\(service.characteristics?.map(\.uuid.uuidString) ?? [])")
                self.failCurrentSession(message)
                return
            }
            self.characteristic = characteristic
            AppLog.ble.notice("发现特征 FFE1，属性=\(Self.describeProperties(characteristic.properties))，开启 Notify")
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    fileprivate nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.sessionGeneration == generation, self.isCurrentSession(peripheral),
                  self.characteristic === characteristic,
                  [.discovering, .ready].contains(self.state) else { return }
            guard error == nil, characteristic.isNotifying else {
                let message = error?.localizedDescription ?? "开启 BMS 通知失败"
                AppLog.ble.error("开启 Notify 失败：\(error?.localizedDescription ?? "isNotifying=false")")
                self.failCurrentSession(message)
                return
            }
            // Notify 开启成功后才开始周期查询。
            guard self.state != .ready else { return }
            self.defaults.set(peripheral.identifier.uuidString, forKey: Self.rememberedDeviceDefaultsKey)
            self.state = .ready
            self.lastError = nil
            AppLog.ble.notice("Notify 已开启，状态进入 ready，启动 \(self.effectiveQueryInterval)s 周期查询")
            self.startQueryTimer()
        }
    }

    fileprivate nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber,
                                           error: Error?, generation: UInt64) {
        let value = RSSI.intValue
        Task { @MainActor [weak self] in
            guard let self, self.sessionGeneration == generation,
                  self.isCurrentSession(peripheral), self.state == .ready else { return }
            guard error == nil, value != 127 else { self.rssi = nil; self.rssiReceivedAt = nil; return }
            self.rssi = value
            self.rssiReceivedAt = Date()
        }
    }

    fileprivate nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?, generation: UInt64) {
        // 在回调入口快照 value，避免 Task 执行时读取下一包覆盖后的 CBCharacteristic.value。
        let value = characteristic.value
        Task { @MainActor [weak self] in
            guard let self, self.sessionGeneration == generation, self.isCurrentSession(peripheral), self.state == .ready,
                  self.characteristic === characteristic, characteristic.isNotifying else { return }
            guard error == nil, let value else {
                self.lastError = error?.localizedDescription ?? "读取 BMS 通知失败"
                AppLog.ble.error("读取通知失败: \(error?.localizedDescription ?? "无数据")")
                return
            }
            AppLog.ble.debug("收到原始通知 \(value.count) 字节: \(LogHexDump.shortenedHex(value))")
            let frames = self.assembler.append(value)
            if !frames.isEmpty {
                AppLog.ble.debug("合包器产出 \(frames.count) 个完整帧")
            }
            for frame in frames {
                AppLog.protocolParser.debug("待解析帧 \(frame.count) 字节: \(LogHexDump.shortenedHex(frame))")
                if let snapshot = AntProtocol.parseStatusResponse(frame) {
                    AppLog.protocolParser.notice("解析成功: \(frame.count) 字节, SOC=\(Int(snapshot.soc))%, 电压=\(String(format: "%.2f", snapshot.totalVoltage))V, 单体=\(snapshot.cellVoltagesMillivolts.count), 温度=\(snapshot.temperatures.count), 未解析尾部=\(snapshot.unparsedBytes) 字节")
                    self.recordSnapshot(snapshot)
                } else {
                    // 解析返回 nil 属正常防御路径，但必须留证：说明帧结构不符预期。
                    AppLog.protocolParser.warning("解析返回 nil（帧被丢弃）: \(frame.count) 字节, 声明长度=\(frame.count >= 6 ? Int(frame[5]) : -1), 原文=\(LogHexDump.shortenedHex(frame, limit: 32))")
                }
            }
        }
    }
}

/// 每个外设会话使用不可变 generation 的 delegate；即使 CoreBluetooth 复用同一对象，
/// 旧 delegate 已发出的异步 Task 也不能污染新会话。弱引用不形成 service 保留环。
private final class BmsPeripheralCallbacks: NSObject, CBPeripheralDelegate {
    private weak var owner: BmsBluetoothService?
    private let generation: UInt64

    init(owner: BmsBluetoothService, generation: UInt64) {
        self.owner = owner
        self.generation = generation
        super.init()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.peripheral(peripheral, didDiscoverServices: error, generation: generation)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        owner?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error, generation: generation)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        owner?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error, generation: generation)
    }
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        owner?.peripheral(peripheral, didReadRSSI: RSSI, error: error, generation: generation)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error, generation: generation)
    }
}
