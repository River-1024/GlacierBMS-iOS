import Combine
import CoreBluetooth
import Foundation
import GlacierBMSDomain

@MainActor
public final class BmsBluetoothService: NSObject, ObservableObject {
    public static let bmsServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    public static let bmsCharacteristicUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")

    @Published public private(set) var state: State = .idle
    @Published public private(set) var latestSnapshot: BmsSnapshot?
    @Published public private(set) var lastError: String?

    public enum State: Equatable {
        case idle
        case poweredOff
        case scanning
        case connecting
        case discovering
        case ready
        case disconnected
    }

    private let central: CBCentralManager
    private let assembler = BmsFrameAssembler()
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?

    public override init() {
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
    }

    public func startScan() {
        guard central.state == .poweredOn else { state = .poweredOff; return }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.bmsServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    public func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        assembler.reset()
        peripheral = nil
        characteristic = nil
        state = .disconnected
    }

    private func sendQueryIfReady() {
        guard let peripheral, let characteristic,
              characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let maximum = peripheral.maximumWriteValueLength(for: type)
        guard maximum >= AntProtocol.queryCommand.count else {
            lastError = "BLE 写入长度不足"
            return
        }
        peripheral.writeValue(AntProtocol.queryCommand, for: characteristic, type: type)
    }
}

extension BmsBluetoothService: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = central.state == .poweredOn ? .idle : .poweredOff
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.peripheral = peripheral
            self.state = .connecting
            central.stopScan()
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .discovering
            peripheral.discoverServices([Self.bmsServiceUUID])
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.assembler.reset()
            self.characteristic = nil
            self.state = .disconnected
            self.lastError = error?.localizedDescription
        }
    }
}

extension BmsBluetoothService: CBPeripheralDelegate {
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.bmsServiceUUID }) else {
                self.lastError = error?.localizedDescription ?? "未找到 BMS 服务"
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
                self.lastError = error?.localizedDescription ?? "未找到 BMS 特征"
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
                return
            }
            self.state = .ready
            self.sendQueryIfReady()
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
                self.latestSnapshot = AntProtocol.parseStatusResponse(frame)
            }
        }
    }
}
