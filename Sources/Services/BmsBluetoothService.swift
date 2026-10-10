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
    /// CoreBluetooth 外设身份；不使用可重名的广播名称隔离设置。
    @Published public private(set) var connectedDeviceID: UUID?
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
            AppLog.ble.warning("启动扫描被拒绝：蓝牙未开启 (central.state=\(central.state.rawValue))")
            return
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
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// 切换设备名过滤开关并持久化。过滤只在发现阶段生效，
    /// 因此需要清空结果并在扫描中时重启扫描才能反映新条件。
    public func setKeywordFilterEnabled(_ enabled: Bool) {
        guard enabled != isKeywordFilterEnabled else { return }
        isKeywordFilterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keywordFilterDefaultsKey)
        AppLog.ble.info("名称过滤开关切换为 \(enabled)")
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
            AppLog.ble.error("连接被拒绝：蓝牙未开启")
            return
        }
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "设备已不可用，请重新扫描"
            AppLog.ble.error("连接被拒绝：retrievePeripherals 未找到 id=\(id.uuidString)")
            return
        }
        stopScan()
        if let previous = peripheral, previous.identifier != id {
            central.cancelPeripheralConnection(previous)
        }
        teardownSession()
        isUserInitiatedDisconnect = false
        peripheral = target
        target.delegate = self
        state = .connecting
        AppLog.ble.notice("发起连接：\(target.name ?? "未命名") id=\(id.uuidString)")
        central.connect(target, options: nil)
    }

    public func disconnect() {
        isUserInitiatedDisconnect = true
        AppLog.ble.notice("用户主动断开：\(connectedDeviceName ?? "未知设备")")
        stopQueryTimer()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        teardownSession()
        state = .disconnected
    }

    private func teardownSession() {
        assembler.reset()
        connectedDeviceID = nil
        connectedDeviceName = nil
        latestSnapshot = nil
        snapshotHistory = []
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
            guard let self else { return }
            if central.state == .poweredOn {
                if self.state == .poweredOff {
                    self.state = self.peripheral == nil ? .idle : .disconnected
                }
                self.lastError = nil
                AppLog.ble.notice("蓝牙状态：已开启 (state=\(self.state))")
            } else {
                AppLog.ble.warning("蓝牙状态变更为 \(central.state.rawValue)（非 poweredOn），清理会话")
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
            guard let self, self.peripheral?.identifier == peripheral.identifier,
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
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            self.teardownSession()
            self.state = .disconnected
            self.lastError = error?.localizedDescription ?? "连接失败"
            AppLog.ble.error("连接失败：\(error?.localizedDescription ?? "未知原因")")
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            self.teardownSession()
            if self.isUserInitiatedDisconnect {
                AppLog.ble.notice("断开完成（用户主动）")
                self.state = .disconnected
                return
            }
            // 意外断开：先清理合包与特征状态，再对同一外设自动重试一次。
            AppLog.ble.warning("意外断开：\(error?.localizedDescription ?? "对端关闭连接")，1 秒后重连")
            self.state = .reconnecting
            self.lastError = error?.localizedDescription
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.state == .reconnecting, !self.isUserInitiatedDisconnect else {
                AppLog.ble.info("重连被取消（状态已变为 \(self.state)）")
                return
            }
            self.state = .connecting
            central.connect(peripheral, options: nil)
        }
    }
}

extension BmsBluetoothService: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.bmsServiceUUID }) else {
                self.lastError = error?.localizedDescription ?? "未找到 BMS 服务 (FFE0)"
                AppLog.ble.error("未发现 BMS 服务 FFE0：\(error?.localizedDescription ?? "服务列表中无 FFE0")，已发现服务=\(peripheral.services?.map(\.uuid.uuidString) ?? [])")
                self.state = .disconnected
                return
            }
            AppLog.ble.notice("发现服务 FFE0，开始发现特征 FFE1")
            peripheral.discoverCharacteristics([Self.bmsCharacteristicUUID], for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            guard error == nil,
                  let characteristic = service.characteristics?.first(where: { $0.uuid == Self.bmsCharacteristicUUID }) else {
                self.lastError = error?.localizedDescription ?? "未找到 BMS 特征 (FFE1)"
                AppLog.ble.error("未发现 BMS 特征 FFE1：\(error?.localizedDescription ?? "特征列表中无 FFE1")，已发现特征=\(service.characteristics?.map(\.uuid.uuidString) ?? [])")
                self.state = .disconnected
                return
            }
            self.characteristic = characteristic
            AppLog.ble.notice("发现特征 FFE1，属性=\(Self.describeProperties(characteristic.properties))，开启 Notify")
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            guard error == nil, characteristic.isNotifying else {
                self.lastError = error?.localizedDescription ?? "开启 BMS 通知失败"
                AppLog.ble.error("开启 Notify 失败：\(error?.localizedDescription ?? "isNotifying=false")")
                self.state = .disconnected
                return
            }
            // Notify 开启成功后才开始周期查询。
            self.state = .ready
            self.lastError = nil
            AppLog.ble.notice("Notify 已开启，状态进入 ready，启动 \(Self.queryInterval)s 周期查询")
            self.startQueryTimer()
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.peripheral?.identifier == peripheral.identifier else { return }
            guard error == nil, let value = characteristic.value else {
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
