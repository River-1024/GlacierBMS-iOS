import ANTuRideDomain
import Combine
import CoreBluetooth
import Foundation

/// 一个结构有效整帧的原子发布值；receivedAt 是手机接收时间，不是控制器硬件时钟。
public struct ControllerTelemetrySnapshot: Equatable, Sendable {
    public let receivedAt: Date
    public let telemetry: MotorControllerTelemetry
}

/// 控制器专用只读会话，不复用 BMS 的 FFE1 特征或 ANT 查询。
/// 唯一写入是 realtimeMonitorCommand()；无控制/参数写入入口。
@MainActor
public final class ControllerBluetoothService: NSObject, ObservableObject {
    // Android MotorControllerBluetoothManager 的真实服务候选与顺序。
    public static let serviceUUIDs = [
        CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FF00-0000-1000-8000-00805F9B34FB")
    ]
    public static let queryInterval: TimeInterval = 0.05
    public static let responseTimeout: TimeInterval = 1
    public static let recordingDuration: TimeInterval = 1800

    public enum State: String {
        case idle, unavailable, scanning, connecting, discovering, enablingNotifications, ready, paused, disconnected, failed
        public var text: String {
            switch self {
            case .idle: return "未连接"
            case .unavailable: return "蓝牙不可用"
            case .scanning: return "扫描中"
            case .connecting: return "连接中"
            case .discovering: return "发现服务中"
            case .enablingNotifications: return "开启通知中"
            case .ready: return "实时查询中"
            case .paused: return "查询已暂停"
            case .disconnected: return "连接已断开"
            case .failed: return "连接失败"
            }
        }
    }

    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published public private(set) var connectedDeviceID: UUID?
    @Published public private(set) var connectedDeviceName: String?
    /// 首页/加速订阅 $latestSnapshot 的事件参数，勿在 @Published willSet 回调中反读属性。
    @Published public private(set) var latestSnapshot: ControllerTelemetrySnapshot?
    public var latestTelemetry: MotorControllerTelemetry? { latestSnapshot?.telemetry }
    public var lastValidAt: Date? { latestSnapshot?.receivedAt }
    @Published public private(set) var lastError: String?
    @Published public private(set) var pendingByteCount = 0
    @Published public private(set) var notificationCount = 0
    @Published public private(set) var frameCount = 0
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordedSampleCount = 0
    @Published public private(set) var recordingSecondsRemaining = 0
    @Published public private(set) var pendingRecord: ControllerHistoryRecord?
    @Published public private(set) var historyRecords: [ControllerHistoryRecord] = []
    @Published public private(set) var historyError: String?
    public let historyStore: ControllerHistoryStore

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var awaitingServices: Set<CBUUID> = []
    private var failedServices: Set<CBUUID> = []
    private var retiringPeripheralIDs: Set<UUID> = []
    private let assembler = MotorControllerFrameAssembler()
    private var timer: Timer?
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private let createsBluetoothManager: Bool
    private var notificationReady = false
    private var pollingEnabled = false // 需 Root 显式启用全局前台轮询。
    private var querySentAt: TimeInterval?
    private var lastValidUptime: TimeInterval?
    private var writeSentAt: TimeInterval?
    private var connectionDeadline: TimeInterval?
    private var recordSession: ControllerRecordSession?
    private var recordStartedAt: Date?
    private var recordDeadline: TimeInterval?
    private var recordDeviceID: UUID?
    private var recordDeviceName = ""

    public convenience init(historyStore: ControllerHistoryStore = ControllerHistoryStore()) {
        self.init(historyStore: historyStore, clock: Date.init,
                  uptime: { ProcessInfo.processInfo.systemUptime }, createsBluetoothManager: true)
    }

    /// 可注入时钟且不创建蓝牙管理器，AppTests 因而不会触发权限或扫描真机。
    init(historyStore: ControllerHistoryStore, clock: @escaping () -> Date,
         uptime: @escaping () -> TimeInterval, createsBluetoothManager: Bool) {
        self.historyStore = historyStore
        self.clock = clock
        self.uptime = uptime
        self.createsBluetoothManager = createsBluetoothManager
        super.init()
        if createsBluetoothManager { central = CBCentralManager(delegate: self, queue: .main) }
    }

    public func startScan() {
        guard let central, central.state == .poweredOn else {
            lastError = "蓝牙未开启或未授权"
            return
        }
        // 不在已有 GATT 会话上切换扫描状态，也不自动选择/连接设备。
        guard peripheral == nil else { lastError = "请先断开当前控制器"; return }
        peripherals.removeAll()
        discoveredDevices = []
        lastError = nil
        state = .scanning
        // 安卓链路允许手动选设备；不要求广播 FFE0，名称也不作为协议凭证。
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    public func connect(to id: UUID) {
        guard let central, central.state == .poweredOn, let device = peripherals[id] else {
            lastError = "设备不可用，请重新扫描"
            return
        }
        guard peripheral == nil else { lastError = "请先断开当前控制器"; return }
        guard !retiringPeripheralIDs.contains(id) else { lastError = "旧连接正在结束，请稍后重试"; return }
        disconnect()
        central.stopScan()
        peripheral = device
        device.delegate = self
        prepareSession(deviceID: id, name: discoveredDevices.first(where: { $0.id == id })?.name ?? device.name ?? "未命名控制器")
        central.connect(device, options: nil)
    }

    public func disconnect() {
        stopRecording()
        central?.stopScan()
        let old = peripheral
        peripheral = nil // 先移除身份，晚到的旧会话回调不会污染新会话。
        old?.delegate = nil
        if let old, old.state != .disconnected {
            retiringPeripheralIDs.insert(old.identifier)
            central?.cancelPeripheralConnection(old)
        }
        timer?.invalidate()
        timer = nil
        characteristic = nil
        awaitingServices.removeAll()
        failedServices.removeAll()
        notificationReady = false
        writeSentAt = nil
        connectionDeadline = nil
        clearRealtime()
        connectedDeviceID = nil
        connectedDeviceName = nil
        state = .disconnected
    }

    /// 由 App/Root 的全局 scenePhase 管理；页面不得互相关闭共享会话。
    /// false 停止扫描/查询、清实时值/半帧并保存记录；不声明控制器后台采样。
    public func setPollingEnabled(_ enabled: Bool) {
        pollingEnabled = enabled
        if !enabled {
            stopScan()
            stopRecording()
            clearRealtime()
        }
        if notificationReady { state = enabled ? .ready : .paused }
    }

    @discardableResult
    public func startRecording() -> Bool {
        tick()
        guard !isRecording, pendingRecord == nil, state == .ready,
              latestTelemetry != nil, let id = connectedDeviceID else { return false }
        recordSession = ControllerRecordSession()
        recordStartedAt = clock()
        recordDeadline = uptime() + Self.recordingDuration
        recordDeviceID = id
        recordDeviceName = connectedDeviceName ?? "未命名控制器"
        recordedSampleCount = 0
        recordingSecondsRemaining = Int(Self.recordingDuration)
        historyError = nil
        isRecording = true
        return true
    }

    /// 仅记录开始后的新整帧；断连/离页/30分钟到期也调用此入口。
    public func stopRecording() {
        guard isRecording, let session = recordSession, let startedAt = recordStartedAt,
              let deviceID = recordDeviceID else { return }
        let samples = session.finish()
        let endedAt = max(max(clock(), samples.last?.timestamp ?? startedAt), startedAt)
        pendingRecord = ControllerHistoryRecord(deviceID: deviceID, deviceName: recordDeviceName,
                                                startedAt: startedAt, endedAt: endedAt, samples: samples)
        isRecording = false
        recordSession = nil
        recordDeadline = nil
        recordingSecondsRemaining = 0
        savePendingRecord()
    }

    /// 保存失败时保留内存快照，禁止新记录覆盖；允许页面显式重试。
    public func savePendingRecord() {
        guard let record = pendingRecord else { return }
        do {
            try historyStore.save(record)
            pendingRecord = nil
            refreshHistory()
        } catch { historyError = "记录保存失败（仍在内存中）：\(error.localizedDescription)" }
    }

    public func refreshHistory() {
        do {
            historyRecords = try historyStore.loadAll()
            historyError = nil
        } catch { historyError = "历史读取失败：\(error.localizedDescription)" }
    }

    public func deleteRecord(id: UUID) {
        do {
            try historyStore.delete(id: id)
            refreshHistory()
        } catch { historyError = "记录删除失败：\(error.localizedDescription)" }
    }

    // MARK: - 会话核心（内部可测试入口；不模拟 CoreBluetooth 成功）

    static func supportsControllerProperties(_ properties: CBCharacteristicProperties) -> Bool {
        properties.contains(.write) && (properties.contains(.notify) || properties.contains(.indicate))
    }

    func prepareSession(deviceID: UUID, name: String) {
        clearRealtime()
        notificationReady = false
        notificationCount = 0
        frameCount = 0
        connectedDeviceID = deviceID
        connectedDeviceName = name
        lastError = nil
        state = .connecting
        connectionDeadline = uptime() + 15
        if createsBluetoothManager {
            timer?.invalidate()
            let timer = Timer(timeInterval: Self.queryInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func notificationsDidBecomeReady() {
        notificationReady = true
        lastError = nil
        connectionDeadline = nil
        state = pollingEnabled ? .ready : .paused
    }

    /// 单请求在途，第一片通知不会放行下一次查询；完整无效帧与 Android 一样结束在途。
    func nextQuery() -> Data? {
        tick()
        guard notificationReady, pollingEnabled, state == .ready,
              querySentAt == nil, writeSentAt == nil else { return nil }
        querySentAt = uptime()
        writeSentAt = querySentAt
        return MotorControllerProtocol.realtimeMonitorCommand()
    }

    func receiveNotification(_ value: Data) {
        tick()
        guard notificationReady, pollingEnabled, state == .ready, querySentAt != nil else { return }
        notificationCount += 1
        let frames = assembler.append(value)
        pendingByteCount = assembler.pendingByteCount
        for frame in frames {
            frameCount += 1
            querySentAt = nil
            switch MotorControllerProtocol.parseRealtimeResponse(frame) {
            case .invalid(let error): lastError = "无效控制器帧：\(error)"
            case .valid(let telemetry):
                let receivedAt = clock()
                lastValidUptime = uptime()
                lastError = nil
                if isRecording, let session = recordSession {
                    // 同一通知可含多个整帧；以最小可表示增量保留本地接收顺序。
                    var sampleAt = receivedAt
                    if let last = session.samples.last, sampleAt <= last.timestamp {
                        sampleAt = Date(timeIntervalSince1970: last.timestamp.timeIntervalSince1970.nextUp)
                    }
                    let sample = ControllerSample(timestamp: sampleAt,
                        voltage: telemetry.controllerVoltageV, current: telemetry.busCurrentA,
                        rpm: telemetry.rpm, speed: .nan, throttle: telemetry.throttleVoltageV,
                        brake: telemetry.linearBrakeVoltageV ?? .nan)
                    if session.append(sample) { recordedSampleCount = session.count }
                }
                // 校验 -> 更新在途/时效 -> 追加记录 -> 一次发布 telemetry + 接收时间。
                latestSnapshot = ControllerTelemetrySnapshot(receivedAt: receivedAt, telemetry: telemetry)
            }
        }
    }

    func queryWriteDidComplete(error: Error? = nil) {
        writeSentAt = nil
        if let error { fail("查询写入失败：\(error.localizedDescription)") }
    }

    func tick() {
        let now = uptime()
        if let sent = writeSentAt, now - sent >= Self.responseTimeout {
            fail("控制器查询写入未确认，已结束会话")
            return
        }
        if let deadline = connectionDeadline, now >= deadline {
            fail("控制器连接或通知开启超时")
            return
        }
        if let sent = querySentAt, now - sent >= Self.responseTimeout {
            clearRealtime()
            lastError = "控制器响应超时"
        }
        if let validAt = lastValidUptime, now - validAt >= Self.responseTimeout {
            lastValidUptime = nil
            latestSnapshot = nil
        }
        if isRecording, let deadline = recordDeadline {
            recordingSecondsRemaining = max(0, Int(ceil(deadline - now)))
            if now >= deadline { stopRecording() }
        }
    }

    private func clearRealtime() {
        assembler.reset()
        pendingByteCount = 0
        querySentAt = nil
        lastValidUptime = nil
        latestSnapshot = nil
    }

    private func poll() {
        tick()
        guard let peripheral, let characteristic, let command = nextQuery() else { return }
        peripheral.writeValue(command, for: characteristic, type: .withResponse)
    }

    private func fail(_ message: String) {
        disconnect()
        lastError = message
        state = .failed
    }

    private func selectCharacteristic() {
        guard awaitingServices.isEmpty, let peripheral else { return }
        // 等全部候选服务回调后按 Android 顺序选，不依赖异步回调先后。
        for uuid in Self.serviceUUIDs {
            guard !failedServices.contains(uuid),
                  let service = peripheral.services?.first(where: { $0.uuid == uuid }),
                  let match = service.characteristics?.first(where: { Self.supportsControllerProperties($0.properties) }) else { continue }
            characteristic = match
            state = .enablingNotifications
            peripheral.setNotifyValue(true, for: match)
            return
        }
        fail("未找到 FFE0/FF00 下支持 write 与 notify/indicate 的控制器特征")
    }
}

extension ControllerBluetoothService: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self, self.central === central else { return }
            if central.state != .poweredOn {
                self.disconnect()
                self.retiringPeripheralIDs.removeAll()
                self.state = .unavailable
                self.lastError = central.state == .unauthorized ? "未授权蓝牙访问" : "蓝牙不可用"
            } else if self.state == .unavailable { self.state = .idle; self.lastError = nil }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                          advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名设备"
        let rssi = RSSI.intValue
        Task { @MainActor [weak self] in
            guard let self, self.central === central, self.state == .scanning else { return }
            self.peripherals[peripheral.identifier] = peripheral
            let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: rssi)
            self.discoveredDevices.removeAll { $0.id == device.id }
            self.discoveredDevices.append(device)
            self.discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, self.state == .connecting else { return }
            self.state = .discovering
            peripheral.discoverServices(Self.serviceUUIDs)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.central === central else { return }
            if self.retiringPeripheralIDs.remove(peripheral.identifier) != nil { return }
            guard self.peripheral === peripheral else { return }
            self.fail(error?.localizedDescription ?? "控制器连接失败")
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.central === central else { return }
            if self.retiringPeripheralIDs.remove(peripheral.identifier) != nil { return }
            guard self.peripheral === peripheral else { return }
            self.disconnect()
            self.lastError = error?.localizedDescription ?? "控制器连接已断开，请手动重连"
        }
    }
}

extension ControllerBluetoothService: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, self.state == .discovering else { return }
            guard error == nil else { self.fail(error!.localizedDescription); return }
            let services = peripheral.services?.filter { Self.serviceUUIDs.contains($0.uuid) } ?? []
            guard !services.isEmpty else { self.fail("设备不含安卓控制器 FFE0/FF00 服务"); return }
            self.awaitingServices = Set(services.map(\.uuid))
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, self.state == .discovering,
                  self.awaitingServices.remove(service.uuid) != nil else { return }
            if let error {
                self.failedServices.insert(service.uuid)
                self.lastError = error.localizedDescription
            }
            self.selectCharacteristic()
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let isNotifying = characteristic.isNotifying
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, self.characteristic === characteristic else { return }
            guard error == nil, isNotifying else { self.fail(error?.localizedDescription ?? "控制器通知未开启"); return }
            self.notificationsDidBecomeReady()
            self.poll()
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, self.characteristic === characteristic else { return }
            self.queryWriteDidComplete(error: error)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // 在委托入口复制通知；不能等 Task 执行时再读可能已被下一包覆盖的 value。
        let value = characteristic.value
        Task { @MainActor [weak self] in
            guard let self, self.peripheral === peripheral, self.characteristic === characteristic else { return }
            guard error == nil, let value else { self.lastError = error?.localizedDescription ?? "控制器通知无数据"; return }
            self.receiveNotification(value)
        }
    }
}
