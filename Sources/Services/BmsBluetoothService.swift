import Combine
import CoreBluetooth
import Foundation
import ANTuRideDomain

/// ANT BMS 蓝牙链路。阶段 1 约束：
/// - 扫描结果以列表呈现，由用户选择设备，不自动连接。
/// - Notify 开启后才允许周期查询。
/// - 意外断开时清理会话后自动重试同一外设一次，不重复创建会话。
@MainActor
public final class BmsBluetoothService: NSObject, ObservableObject {
    public static let bmsServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    public static let bmsCharacteristicUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    /// 周期查询间隔，与 Android 端节奏一致。
    public static let queryInterval: TimeInterval = 1.0
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
    @Published public private(set) var latestSnapshot: BmsSnapshot?
    @Published public private(set) var snapshotHistory: [BmsSnapshot] = []
    @Published public private(set) var lastError: String?
    /// 是否按设备名关键字过滤扫描结果。默认开启；关闭后列出附近全部蓝牙设备。
    @Published public private(set) var isKeywordFilterEnabled: Bool = true

    private let central: CBCentralManager
    private let assembler = BmsFrameAssembler()
    private let maximumHistoryCount = 120

    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var queryTimer: Timer?
    private var isUserInitiatedDisconnect = false
    private var deviceSummaries: [UUID: DiscoveredDevice] = [:]

    public override init() {
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        isKeywordFilterEnabled = UserDefaults.standard.object(forKey: Self.keywordFilterDefaultsKey) as? Bool ?? true
        central.delegate = self
    }

    // MARK: - 扫描

    public func startScan() {
        guard central.state == .poweredOn else {
            state = .poweredOff
            lastError = "蓝牙未开启"
            return
        }
        deviceSummaries.removeAll()
        discoveredDevices = []
        state = .scanning
        beginScan()
    }

    /// 开启一次扫描。不按服务过滤扫描：部分 ANT BMS 固件不广播 FFE0，
    /// 由 didDiscover 回调按广播服务与名称关键字过滤。
    private func beginScan() {
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// 切换设备名过滤开关并持久化。过滤只在发现阶段生效，
    /// 因此需要清空结果并在扫描中时重启扫描才能反映新条件。
    public func setKeywordFilterEnabled(_ enabled: Bool) {
        guard enabled != isKeywordFilterEnabled else { return }
        isKeywordFilterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keywordFilterDefaultsKey)
        deviceSummaries.removeAll()
        discoveredDevices = []
        guard central.state == .poweredOn, state == .scanning else { return }
        central.stopScan()
        beginScan()
    }

    public func stopScan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    // MARK: - 连接

    public func connect(to id: UUID) {
        guard central.state == .poweredOn else {
            state = .poweredOff
            lastError = "蓝牙未开启"
            return
        }
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "设备已不可用，请重新扫描"
            return
        }
        stopScan()
        isUserInitiatedDisconnect = false
        peripheral = target
        target.delegate = self
        state = .connecting
        central.connect(target, options: nil)
    }

    public func disconnect() {
        isUserInitiatedDisconnect = true
        stopQueryTimer()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        teardownSession()
        state = .disconnected
    }

    private func teardownSession() {
        assembler.reset()
        characteristic = nil
        stopQueryTimer()
    }

    // MARK: - 周期查询

    private func startQueryTimer() {
        stopQueryTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.queryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendQueryIfReady()
            }
        }
        queryTimer = timer
        sendQueryIfReady()
    }

    private func stopQueryTimer() {
        queryTimer?.invalidate()
        queryTimer = nil
    }

    private func sendQueryIfReady() {
        guard state == .ready, let peripheral, let characteristic else { return }
        if characteristic.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else { return }
            peripheral.writeValue(AntProtocol.queryCommand, for: characteristic, type: .withoutResponse)
        } else if characteristic.properties.contains(.write) {
            peripheral.writeValue(AntProtocol.queryCommand, for: characteristic, type: .withResponse)
        }
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
            guard let self else { return }
            if central.state == .poweredOn {
                if self.state == .poweredOff {
                    self.state = self.peripheral == nil ? .idle : .disconnected
                }
                self.lastError = nil
            } else {
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
            guard let self else { return }
            guard self.isCandidate(advertisedServices: advertisedServices, name: resolvedName) else { return }
            let device = DiscoveredDevice(id: peripheral.identifier, name: resolvedName, rssi: RSSI.intValue)
            self.deviceSummaries[device.id] = device
            self.discoveredDevices = self.deviceSummaries.values.sorted { $0.rssi > $1.rssi }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .discovering
            self.connectedDeviceName = peripheral.name ?? self.deviceSummaries[peripheral.identifier]?.name
            peripheral.discoverServices([Self.bmsServiceUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.teardownSession()
            self.state = .disconnected
            self.lastError = error?.localizedDescription ?? "连接失败"
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.teardownSession()
            if self.isUserInitiatedDisconnect {
                self.state = .disconnected
                return
            }
            // 意外断开：先清理合包与特征状态，再对同一外设自动重试一次。
            self.state = .reconnecting
            self.lastError = error?.localizedDescription
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.state == .reconnecting, !self.isUserInitiatedDisconnect else { return }
            self.state = .connecting
            central.connect(peripheral, options: nil)
        }
    }
}

extension BmsBluetoothService: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.bmsServiceUUID }) else {
                self.lastError = error?.localizedDescription ?? "未找到 BMS 服务 (FFE0)"
                self.state = .disconnected
                return
            }
            peripheral.discoverCharacteristics([Self.bmsCharacteristicUUID], for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil,
                  let characteristic = service.characteristics?.first(where: { $0.uuid == Self.bmsCharacteristicUUID }) else {
                self.lastError = error?.localizedDescription ?? "未找到 BMS 特征 (FFE1)"
                self.state = .disconnected
                return
            }
            self.characteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil, characteristic.isNotifying else {
                self.lastError = error?.localizedDescription ?? "开启 BMS 通知失败"
                self.state = .disconnected
                return
            }
            // Notify 开启成功后才开始周期查询。
            self.state = .ready
            self.lastError = nil
            self.startQueryTimer()
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil, let value = characteristic.value else {
                self.lastError = error?.localizedDescription ?? "读取 BMS 通知失败"
                return
            }
            for frame in self.assembler.append(value) {
                if let snapshot = AntProtocol.parseStatusResponse(frame) {
                    self.recordSnapshot(snapshot)
                }
            }
        }
    }
}
