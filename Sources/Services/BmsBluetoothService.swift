import Combine
import CoreBluetooth
import Foundation
import ANTuRideDomain

/// 兼容既有设置回归测试入口，实际生命周期使用共享策略。
typealias BmsStartupConnectionPolicy = DeviceAutoConnectionPolicy

/// ANT BMS 蓝牙链路：
/// - 每次前台会话仅自动尝试记忆 UUID 一次，搜索及握手共用有限超时。
/// - Notify 开启后才允许周期查询；首个有效状态帧才更新记忆。
/// - 后台不搜索、不查询；手动断开抑制本次进程自动连接。
@MainActor
public final class BmsBluetoothService: NSObject, ObservableObject {
    public static let bmsServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    public static let bmsCharacteristicUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    /// 周期查询间隔，与 Android 端节奏一致。
    public static let queryInterval: TimeInterval = 1.0
    static let rememberedDeviceDefaultsKey = "com.zjsf.anturide.bms.lastPeripheralUUID"
    @Published public private(set) var effectiveQueryInterval: TimeInterval = BmsBluetoothService.queryInterval
    static let rememberedDeviceNameDefaultsKey = "com.zjsf.anturide.bms.lastPeripheralName"
    static let keywordFilterDefaultsKey = "com.zjsf.anturide.bms.nameFilterEnabled"
    private static let legacyKeywordFilterDefaultsKey = "com.zjsf.anturide.deviceKeywordFilterEnabled"
    static let connectionTimeout: TimeInterval = 10

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
    @Published public private(set) var rememberedDeviceID: UUID?
    @Published public private(set) var rememberedDeviceName: String?
    public var isConnectionActive: Bool {
        pendingConnectionID != nil || automaticSearchTargetID != nil
            || [.connecting, .discovering, .ready, .reconnecting].contains(state)
    }
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
    private let registry: BluetoothDeviceRegistry
    private let uptime: () -> TimeInterval
    private var connectionPolicy = DeviceAutoConnectionPolicy()
    private(set) var isForeground = false
    private(set) var automaticSearchTargetID: UUID?
    private(set) var connectionDeadline: TimeInterval?
    private var connectionTimeoutTask: Task<Void, Never>?
    private(set) var connectionAttemptGeneration: UInt64 = 0
    private var retiringPeripheralIDs = Set<UUID>()
    private var claimedDeviceIDs = Set<UUID>()
    private var pendingConnectionID: UUID?
    private(set) var sessionGeneration: UInt64 = 0
    private(set) var queryGeneration: UInt64 = 0
    private let assembler = BmsFrameAssembler()
    private let maximumHistoryCount = 120

    private var peripheral: CBPeripheral?
    private var peripheralCallbacks: BmsPeripheralCallbacks?
    private var characteristic: CBCharacteristic?
    private var queryTimer: Timer?
    private var isUserInitiatedDisconnect = false
    private var deviceSummaries: [UUID: DiscoveredDevice] = [:]
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    public override convenience init() {
        self.init(defaults: .standard, startupAutoConnectEnabled: true, queryIntervalMs: 1000)
    }

    /// 配置在 delegate 安装前确定，避免首次 poweredOn 先读取默认开启再读用户关闭偏好。
    /// createsBluetoothManager=false 仅供无硬件单元测试，不会创建 manager 或请求权限。
    public init(defaults: UserDefaults = .standard, startupAutoConnectEnabled: Bool,
                queryIntervalMs: Int, createsBluetoothManager: Bool = true,
                registry: BluetoothDeviceRegistry? = nil,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.startupAutoConnectEnabled = startupAutoConnectEnabled
        self.registry = registry ?? .shared
        self.uptime = uptime
        central = createsBluetoothManager ? CBCentralManager(delegate: nil, queue: .main) : nil
        super.init()
        effectiveQueryInterval = Self.normalizedQueryInterval(milliseconds: queryIntervalMs)
        if defaults.object(forKey: Self.keywordFilterDefaultsKey) == nil,
           let legacy = defaults.object(forKey: Self.legacyKeywordFilterDefaultsKey) as? Bool {
            defaults.set(legacy, forKey: Self.keywordFilterDefaultsKey)
        }
        isKeywordFilterEnabled = defaults.object(forKey: Self.keywordFilterDefaultsKey) as? Bool ?? true
        rememberedDeviceID = defaults.string(forKey: Self.rememberedDeviceDefaultsKey).flatMap(UUID.init(uuidString:))
        rememberedDeviceName = rememberedDeviceID == nil ? nil : defaults.string(forKey: Self.rememberedDeviceNameDefaultsKey)
        central?.delegate = self
    }

    public func applyDrivingSettings(_ settings: DrivingSettings) {
        startupAutoConnectEnabled = settings.bmsAutoConnectEnabled
        if !startupAutoConnectEnabled, automaticSearchTargetID != nil {
            cancelConnectionAttempt()
            discardPendingConnection()
            retireCurrentPeripheral()
            state = .disconnected
        }
        let interval = Self.normalizedQueryInterval(milliseconds: settings.bluetoothRefreshIntervalMs)
        guard effectiveQueryInterval != interval else { return }
        effectiveQueryInterval = interval
        if state == .ready { startQueryTimer() }
    }

    static func normalizedQueryInterval(milliseconds: Int) -> TimeInterval {
        let bounds = DrivingSettings.bluetoothRefreshIntervalMsBounds
        return TimeInterval(min(max(milliseconds, bounds.lowerBound), bounds.upperBound)) / 1000
    }

    /// 只在真正的 background -> active 边沿重置机会，重复 active 通知不抢连。
    public func beginForegroundSession() {
        if !isForeground {
            isForeground = true
            connectionPolicy.beginForegroundSession()
        }
        if state == .ready { startQueryTimer() }
        attemptAutomaticConnection()
    }

    public func pauseForBackground() {
        guard isForeground else { return }
        isForeground = false
        let hasUnverifiedReadyConnection = state == .ready && latestSnapshot == nil
        cancelConnectionAttempt()
        stopScan()
        stopQueryTimer()
        discardPendingConnection()
        if hasUnverifiedReadyConnection || [.connecting, .discovering, .reconnecting].contains(state) {
            retireCurrentPeripheral()
            state = .disconnected
        }
    }

    public func reconnectRememberedDevice() {
        connectionPolicy.allowManualConnection()
        cancelConnectionAttempt()
        discardPendingConnection()
        guard let id = rememberedDeviceID else {
            lastError = "没有已记忆的 BMS，请先扫描连接"
            return
        }
        requestConnection(to: id, allowsDirectedScan: true)
    }

    public func forgetDevice() {
        disconnect()
        defaults.removeObject(forKey: Self.rememberedDeviceDefaultsKey)
        defaults.removeObject(forKey: Self.rememberedDeviceNameDefaultsKey)
        rememberedDeviceID = nil
        rememberedDeviceName = nil
    }

    // 独立于 CBManager 的策略边界，供无硬件测试验证生命周期接线。
    func consumeAutomaticTarget(poweredOn: Bool) -> UUID? {
        guard isForeground else { return nil }
        return connectionPolicy.consumeTarget(poweredOn: poweredOn, enabled: startupAutoConnectEnabled,
                                              rememberedID: rememberedDeviceID, hasActiveSession: isConnectionActive)
    }

    private func attemptAutomaticConnection() {
        guard let id = consumeAutomaticTarget(poweredOn: central?.state == .poweredOn) else { return }
        requestConnection(to: id, allowsDirectedScan: true)
    }

    /// Task.sleep 与 uptime 均为单调时间；generation 使已排队的旧超时不能终止新连接。
    func beginConnectionAttempt(searchTargetID: UUID? = nil) {
        cancelConnectionAttempt()
        automaticSearchTargetID = searchTargetID
        connectionDeadline = uptime() + Self.connectionTimeout
        let generation = connectionAttemptGeneration
        connectionTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(Self.connectionTimeout * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            self.expireConnectionAttemptIfNeeded(generation: generation)
        }
    }

    @discardableResult
    func expireConnectionAttemptIfNeeded(generation: UInt64) -> Bool {
        guard connectionAttemptGeneration == generation, let deadline = connectionDeadline,
              uptime() >= deadline else { return false }
        failCurrentSession("BMS 搜索或连接超时，请手动重试")
        return true
    }

    private func cancelConnectionAttempt() {
        connectionAttemptGeneration &+= 1
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionDeadline = nil
        if automaticSearchTargetID != nil { central?.stopScan() }
        automaticSearchTargetID = nil
    }

    private func discardPendingConnection() {
        if let id = pendingConnectionID, id != connectedDeviceID, !retiringPeripheralIDs.contains(id) {
            releaseClaim(for: id)
        }
        pendingConnectionID = nil
    }

    private func releaseClaim(for id: UUID) {
        registry.release(id, for: .battery)
        claimedDeviceIDs.remove(id)
    }

    // MARK: - 扫描

    public func startScan() {
        connectionPolicy.suppressForForegroundSession()
        cancelConnectionAttempt()
        discardPendingConnection()
        guard isForeground else { return }
        guard let central, central.state == .poweredOn else {
            state = .poweredOff
            lastError = "蓝牙未开启"
            AppLog.ble.warning("启动扫描被拒绝：蓝牙未开启 (central.state=\(self.central?.state.rawValue ?? -1))")
            return
        }
        if isConnectionActive {
            discardPendingConnection()
            isUserInitiatedDisconnect = true
            retireCurrentPeripheral()
        }
        deviceSummaries.removeAll()
        discoveredPeripherals.removeAll()
        discoveredDevices = []
        state = .scanning
        AppLog.ble.notice("开始扫描 (名称过滤=\(isKeywordFilterEnabled)，角色=battery/ant)")
        beginScan()
    }

    /// 开启一次扫描。不按服务过滤扫描：部分 ANT BMS 固件不广播 FFE0，
    /// 手动候选列表按电池名称过滤；自动定向回退在 didDiscover 中只按记忆 UUID 接受。
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

    /// 停止普通手动扫描。自动定向搜索属于启动/前台自动连接，不能被设置页离开取消。
    public func stopManualScan() {
        guard automaticSearchTargetID == nil else { return }
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    /// 兼容旧调用方；自动目标同样不会被这个入口取消。
    public func stopScan() {
        stopManualScan()
    }

    // MARK: - 连接

    public func connect(to id: UUID) {
        connectionPolicy.allowManualConnection()
        connectionPolicy.suppressForForegroundSession()
        cancelConnectionAttempt()
        discardPendingConnection()
        requestConnection(to: id)
    }

    private func requestConnection(to id: UUID, allowsDirectedScan: Bool = false) {
        guard isForeground else { return }
        guard let central, central.state == .poweredOn else {
            lastError = "蓝牙未开启"
            return
        }
        guard registry.owner(of: id) != .controller else {
            lastError = "该设备已由控制器使用，不能作为 BMS 连接"
            return
        }
        if connectedDeviceID == id, [.connecting, .discovering, .ready].contains(state) {
            if state != .ready || latestSnapshot == nil {
                beginConnectionAttempt(searchTargetID: allowsDirectedScan ? id : nil)
            }
            return
        }
        let target = discoveredPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard allowsDirectedScan || target != nil else {
            lastError = "设备已不可用，请重新扫描"
            return
        }
        guard registry.claim(id, for: .battery) else {
            lastError = "该设备已被其他角色占用"
            return
        }
        claimedDeviceIDs.insert(id)
        central.stopScan()
        pendingConnectionID = id
        isUserInitiatedDisconnect = false
        // 先退休旧会话；同 UUID 必须收到终止回调才可连接。
        retireCurrentPeripheral()
        beginConnectionAttempt(searchTargetID: allowsDirectedScan ? id : nil)
        if let target {
            discoveredPeripherals[id] = target
            startPendingConnectionIfPossible()
        } else {
            state = .scanning
            beginScan()
        }
    }

    private func retireCurrentPeripheral() {
        let previous = peripheral
        let previousID = previous?.identifier ?? connectedDeviceID
        peripheral = nil
        previous?.delegate = nil
        teardownSession()
        if let previousID {
            if let previous, previous.state == .disconnected {
                releaseClaim(for: previousID)
            } else {
                retiringPeripheralIDs.insert(previousID)
                if let previous { central?.cancelPeripheralConnection(previous) }
            }
        }
    }

    private func startPendingConnectionIfPossible() {
        guard isForeground, let central, central.state == .poweredOn, !isUserInitiatedDisconnect,
              let id = pendingConnectionID, !retiringPeripheralIDs.contains(id) else { return }
        guard !expireConnectionAttemptIfNeeded(generation: connectionAttemptGeneration) else { return }
        guard let target = discoveredPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            // 定向搜索继续使用原 deadline，不为每次回调续期。
            if automaticSearchTargetID == id { state = .scanning; beginScan(); return }
            failCurrentSession("BMS 已不可用，请重新扫描")
            return
        }
        let name = deviceSummaries[id]?.name ?? target.name ?? (id == rememberedDeviceID ? rememberedDeviceName : nil)
        // 自动回退由 CoreBluetooth UUID 定位；记忆设备改名时仍必须尝试并在协议层验证，
        // 但绝不放行其他 UUID。严格 ant 过滤只约束手动候选列表。
        if automaticSearchTargetID != id && !isCandidate(advertisedServices: [], name: name ?? "") {
            failCurrentSession("设备名称不匹配 ANT 电池过滤条件")
            return
        }
        central.stopScan()
        pendingConnectionID = nil
        guard prepareSession(deviceID: id, name: name) else {
            releaseClaim(for: id)
            cancelConnectionAttempt()
            state = .disconnected
            return
        }
        peripheral = target
        installPeripheralCallbacks(for: target)
        AppLog.ble.notice("发起连接：\(target.name ?? "未命名") id=\(id.uuidString)")
        central.connect(target, options: nil)
    }

    /// 真实链路与无 CBManager 测试共用的 claim / session 边界。
    @discardableResult
    func prepareSession(deviceID: UUID, name: String?) -> Bool {
        guard isForeground, connectedDeviceID == nil, peripheral == nil, !retiringPeripheralIDs.contains(deviceID),
              registry.claim(deviceID, for: .battery) else {
            lastError = "该设备仍被占用或旧连接尚未退出"
            return false
        }
        claimedDeviceIDs.insert(deviceID)
        teardownSession()
        isUserInitiatedDisconnect = false
        connectedDeviceID = deviceID
        connectedDeviceName = name
        state = .connecting
        lastError = nil
        return true
    }

    @discardableResult
    func completeRetirement(deviceID: UUID) -> Bool {
        guard retiringPeripheralIDs.remove(deviceID) != nil else { return false }
        releaseClaim(for: deviceID)
        startPendingConnectionIfPossible()
        return true
    }

    @discardableResult
    func connectionDidTerminate(deviceID: UUID, generation: UInt64, error: String?) -> Bool {
        guard generation == sessionGeneration, connectedDeviceID == deviceID,
              [.connecting, .discovering, .ready].contains(state) else { return false }
        cancelConnectionAttempt()
        releaseClaim(for: deviceID)
        peripheral?.delegate = nil
        peripheral = nil
        pendingConnectionID = nil
        teardownSession()
        state = .disconnected
        lastError = error
        return true
    }

    public func disconnect() {
        connectionPolicy.suppressForRun()
        cancelConnectionAttempt()
        central?.stopScan()
        isUserInitiatedDisconnect = true
        discardPendingConnection()
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
        cancelConnectionAttempt()
        central?.stopScan()
        discardPendingConnection()
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
        guard isForeground, state == .ready, peripheral != nil else { return }
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
        guard isForeground, state == .ready, let peripheral, isCurrentSession(peripheral),
              let characteristic, characteristic.isNotifying else { return }
        guard !expireConnectionAttemptIfNeeded(generation: connectionAttemptGeneration) else { return }
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

    func isCandidate(advertisedServices: [CBUUID], name: String) -> Bool {
        BluetoothDeviceNameFilter.matches(name, role: .battery, enabled: isKeywordFilterEnabled)
    }

    func matchesDiscoveredDevice(deviceID: UUID, name: String) -> Bool {
        guard isForeground, registry.owner(of: deviceID) != .controller else { return false }
        if let id = automaticSearchTargetID {
            // 定向扫描只接受记忆 UUID；名称可变，不参与自动身份判断。
            return id == deviceID
        }
        return isCandidate(advertisedServices: [], name: name)
    }

    func notificationsDidBecomeReady(deviceID: UUID, generation: UInt64) {
        guard sessionGeneration == generation, connectedDeviceID == deviceID,
              state == .discovering || state == .connecting else { return }
        guard !expireConnectionAttemptIfNeeded(generation: connectionAttemptGeneration) else { return }
        state = .ready
        lastError = nil
        // ready 是传输可查询，不代表已有有效实时数据；latestSnapshot 仍为空。
        startQueryTimer()
    }

    func receiveNotification(_ value: Data, deviceID: UUID, generation: UInt64) {
        guard isForeground, state == .ready, sessionGeneration == generation,
              connectedDeviceID == deviceID, !retiringPeripheralIDs.contains(deviceID),
              !isUserInitiatedDisconnect else { return }
        guard !expireConnectionAttemptIfNeeded(generation: connectionAttemptGeneration) else { return }
        AppLog.ble.debug("收到原始通知 \(value.count) 字节: \(LogHexDump.shortenedHex(value))")
        for frame in assembler.append(value) {
            if let snapshot = AntProtocol.parseStatusResponse(frame) {
                cancelConnectionAttempt()
                if rememberedDeviceID != deviceID || rememberedDeviceName != connectedDeviceName {
                    defaults.set(deviceID.uuidString, forKey: Self.rememberedDeviceDefaultsKey)
                    defaults.set(connectedDeviceName, forKey: Self.rememberedDeviceNameDefaultsKey)
                    rememberedDeviceID = deviceID
                    rememberedDeviceName = connectedDeviceName
                }
                recordSnapshot(snapshot)
            } else {
                AppLog.protocolParser.warning("ANT 状态帧校验失败，未更新记忆: \(LogHexDump.shortenedHex(frame, limit: 32))")
            }
        }
    }

    func bluetoothDidPowerOff() {
        cancelConnectionAttempt()
        central?.stopScan()
        peripheral?.delegate = nil
        for id in claimedDeviceIDs { registry.release(id, for: .battery) }
        claimedDeviceIDs.removeAll()
        peripheral = nil
        pendingConnectionID = nil
        retiringPeripheralIDs.removeAll()
        discoveredPeripherals.removeAll()
        deviceSummaries.removeAll()
        discoveredDevices = []
        teardownSession()
        state = .poweredOff
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
                self.attemptAutomaticConnection()
            } else {
                AppLog.ble.warning("蓝牙状态变更为 \(central.state.rawValue)（非 poweredOn），清理会话")
                self.bluetoothDidPowerOff()
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let resolvedName = localName ?? peripheral.name ?? "未命名设备"
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central, central.state == .poweredOn,
                  self.isForeground, self.state == .scanning else { return }
            guard !self.expireConnectionAttemptIfNeeded(generation: self.connectionAttemptGeneration) else { return }
            guard self.matchesDiscoveredDevice(deviceID: peripheral.identifier, name: resolvedName) else {
                AppLog.ble.debug("过滤设备：\(resolvedName) (广播服务=\(advertisedServices.map(\.uuidString)))")
                return
            }
            let device = DiscoveredDevice(id: peripheral.identifier, name: resolvedName, rssi: RSSI.intValue)
            if self.deviceSummaries[device.id] == nil {
                AppLog.ble.info("发现候选设备：\(resolvedName) RSSI=\(RSSI.intValue) dBm id=\(peripheral.identifier.uuidString)")
            }
            self.deviceSummaries[device.id] = device
            self.discoveredPeripherals[device.id] = peripheral
            if self.automaticSearchTargetID == device.id {
                central.stopScan()
                self.startPendingConnectionIfPossible()
                return
            }
            self.discoveredDevices = self.deviceSummaries.values.sorted { $0.rssi > $1.rssi }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central, self.isCurrentSession(peripheral),
                  self.state == .connecting else { return }
            self.connectedDeviceID = peripheral.identifier
            self.state = .discovering
            self.connectedDeviceName = self.deviceSummaries[peripheral.identifier]?.name ?? peripheral.name ?? self.connectedDeviceName
            AppLog.ble.notice("已连接外设：\(self.connectedDeviceName ?? "未命名")，开始发现服务 FFE0")
            peripheral.discoverServices([Self.bmsServiceUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central else { return }
            if self.completeRetirement(deviceID: peripheral.identifier) { return }
            guard self.isCurrentSession(peripheral), self.state == .connecting else { return }
            self.connectionDidTerminate(deviceID: peripheral.identifier, generation: self.sessionGeneration,
                                       error: error?.localizedDescription ?? "连接失败")
            AppLog.ble.error("连接失败：\(error?.localizedDescription ?? "未知原因")")
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let ownCentral = self.central, ownCentral === central else { return }
            if self.completeRetirement(deviceID: peripheral.identifier) { return }
            guard self.isCurrentSession(peripheral),
                  [.connecting, .discovering, .ready].contains(self.state) else { return }
            self.connectionDidTerminate(deviceID: peripheral.identifier, generation: self.sessionGeneration,
                                       error: error?.localizedDescription)
            // 不在同一前台会话无限抢连；下一前台边沿由共享策略决定一次尝试。
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
            self.notificationsDidBecomeReady(deviceID: peripheral.identifier, generation: generation)
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
            self.receiveNotification(value, deviceID: peripheral.identifier, generation: generation)
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
