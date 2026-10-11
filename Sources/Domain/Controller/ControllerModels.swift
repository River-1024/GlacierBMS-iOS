import Foundation

/// A single read-only motor-controller sample.
///
/// `telemetry` is optional so records written before the 18-column model remain
/// decodable. The legacy seven fields remain intact; missing telemetry is never invented.
public struct ControllerSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let voltage: Double
    public let current: Double
    public let rpm: Int
    public let speed: Double
    public let throttle: Double
    public let brake: Double
    public let telemetry: MotorControllerTelemetry?

    public init(
        timestamp: Date,
        voltage: Double,
        current: Double,
        rpm: Int,
        speed: Double,
        throttle: Double,
        brake: Double,
        telemetry: MotorControllerTelemetry? = nil
    ) {
        self.timestamp = timestamp
        self.voltage = voltage
        self.current = current
        self.rpm = rpm
        self.speed = speed
        self.throttle = throttle
        self.brake = brake
        self.telemetry = telemetry
    }
}

/// Android 控制器记录导出的 18 列，列名和顺序与 ControllerRecordExporter.kt 一致。
public enum ControllerRecordColumns {
    public static let headers = [
        "电压", "母线电流", "转速", "电控温度", "电机温度", "相线峰值电流",
        "油门电压", "档位", "控制器状态", "故障信息", "端口状态", "给定Iq",
        "反馈Iq", "给定Id", "弱磁", "控制器历史故障", "线性刹车电压", "时间"
    ]

    private static let stateBitNames = [
        "P档", "前进", "倒车", "防盗", "刹车", "侧撑", "定速巡航", "充电保护",
        "自学习", "驻车", "TCS", "限速", "应急", "请自学习"
    ]

    private static let faultBitNames = [
        "霍尔故障", "硬件过流", "相过流", "过压", "欠压", "转把故障", "控制器过温",
        "电机过温", "堵转保护", "缺相保护", "Mosfet故障", "相传感器偏置故障",
        "母线传感器偏置故障", "控制器温度传感器故障", "电机温度传感器故障"
    ]

    public static func row(for sample: ControllerSample, timeZone: TimeZone = .current) -> [String] {
        guard let telemetry = sample.telemetry else {
            // Old JSON still supplies these confirmed measurements, but no temperatures/bitmaps.
            return [
                decimal(sample.voltage, digits: 1) + "V",
                decimal(sample.current, digits: 1) + "A", "\(sample.rpm)RPM",
                "--", "--", "--", decimal(sample.throttle, digits: 2) + "V",
                "--", "--", "--", "--", "--", "--", "--", "--", "--",
                decimal(sample.brake, digits: 2) + "V", timestamp(sample.timestamp, timeZone: timeZone)
            ]
        }
        return [
            decimal(telemetry.controllerVoltageV, digits: 1) + "V",
            decimal(telemetry.busCurrentA, digits: 1) + "A",
            "\(telemetry.rpm)RPM",
            "\(telemetry.controllerTemperatureC)℃",
            "\(telemetry.motorTemperatureC)℃",
            decimal(telemetry.phasePeakCurrentA, digits: 1) + "A",
            decimal(telemetry.throttleVoltageV, digits: 2) + "V",
            String(format: "%x", telemetry.gear & 0x0F),
            bitNames(telemetry.controllerStateBits, names: stateBitNames),
            bitNames(telemetry.faultBits, names: faultBitNames),
            String(telemetry.portStatusBits),
            decimal(telemetry.givenIqA, digits: 1) + "A",
            decimal(telemetry.feedbackIqA, digits: 1) + "A",
            decimal(telemetry.givenIdA, digits: 1) + "A",
            decimal(telemetry.fieldWeakeningA, digits: 1) + "A",
            bitNames(telemetry.historyFaultBits, names: faultBitNames),
            decimal(telemetry.linearBrakeVoltageV, digits: 2) + "V",
            timestamp(sample.timestamp, timeZone: timeZone)
        ]
    }

    private static func decimal(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }

    private static func bitNames(_ bits: Int, names: [String]) -> String {
        let masked = bits & 0xFFFF
        return names.enumerated().compactMap { index, name in
            masked & (1 << index) != 0 ? name : nil
        }.joined(separator: ",")
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// In-memory controller recording session. It deliberately has no UI or Bluetooth concerns.
public final class ControllerRecordSession: @unchecked Sendable {
    public static let csvHeader = "timestamp,voltage,current,rpm,speed,throttle,brake"
    public static let controllerCSVHeader = ControllerRecordColumns.headers.joined(separator: ",")

    private var recordedSamples: [ControllerSample] = []
    public private(set) var isFinished = false

    public init() {}

    public var samples: [ControllerSample] { recordedSamples }
    public var count: Int { recordedSamples.count }

    @discardableResult
    public func append(_ sample: ControllerSample) -> Bool {
        let seconds = sample.timestamp.timeIntervalSince1970
        guard !isFinished, seconds.isFinite,
              seconds >= -62_135_596_800, seconds < 253_402_300_800 else { return false }
        if let last = recordedSamples.last, sample.timestamp <= last.timestamp { return false }
        recordedSamples.append(sample)
        return true
    }

    @discardableResult
    public func finish() -> [ControllerSample] {
        isFinished = true
        return recordedSamples
    }

    /// Legacy seven-column CSV API, kept for existing callers.
    public func exportCSV() -> String {
        let rows = recordedSamples.map { sample in
            [
                csvTimestamp(sample.timestamp), csvNumber(sample.voltage), csvNumber(sample.current),
                String(sample.rpm), csvNumber(sample.speed), csvNumber(sample.throttle), csvNumber(sample.brake)
            ].map(csvEscape).joined(separator: ",")
        }
        return ([Self.csvHeader] + rows).joined(separator: "\n") + "\n"
    }

    /// Android-compatible 18-column CSV. Newest samples are first, like the Android XLSX exporter.
    /// Timestamp text has second resolution; it is phone receive time, not hardware clock precision.
    public func exportControllerCSV(timeZone: TimeZone = .current) -> String {
        let rows = recordedSamples.reversed().map {
            ControllerRecordColumns.row(for: $0, timeZone: timeZone).map(csvEscape).joined(separator: ",")
        }
        return ([Self.controllerCSVHeader] + rows).joined(separator: "\n") + "\n"
    }

    public func exportControllerXLSX(timeZone: TimeZone = .current) throws -> Data {
        try ControllerWorkbook.data(headers: ControllerRecordColumns.headers,
                                rows: recordedSamples.reversed().map {
                                    ControllerRecordColumns.row(for: $0, timeZone: timeZone)
                                })
    }

    private func csvTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func csvNumber(_ value: Double) -> String { value.isFinite ? String(value) : "" }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Reassembles controller notifications using the Android protocol's `6 + LEN + 2` boundary.
/// The first three bytes are intentionally not interpreted; command/address at offsets 3/4
/// identify a real-time response and byte 5 declares the data-region length.
/// `0x0D` may occur anywhere in the payload; there is no delimiter/tail byte.
/// Reset on connect/disconnect, polling pause or query timeout, just like Android.
public final class MotorControllerFrameAssembler {
    public static let realtimeCommand = MotorControllerProtocol.realtimeCommand
    public static let realtimeAddress = MotorControllerProtocol.realtimeAddress

    private var buffer: [UInt8] = []
    private let maximumFrameLength: Int

    public init(maximumFrameLength: Int = 512) {
        self.maximumFrameLength = max(8, maximumFrameLength)
    }

    public var pendingByteCount: Int { buffer.count }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Returns complete frames; malformed, zero-length, or over-limit candidates are skipped safely.
    public func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(contentsOf: chunk)
        var frames: [Data] = []

        while true {
            guard let candidate = findCandidateStart() else {
                retainPossiblePrefix()
                break
            }

            if candidate > 0 {
                buffer.removeFirst(candidate)
            }
            guard buffer.count >= 6 else { break }

            let dataLength = Int(buffer[5])
            let expectedLength = MotorControllerProtocol.responseDataRegionOffset + dataLength +
                MotorControllerProtocol.checksumLength
            if dataLength == 0 || expectedLength > maximumFrameLength {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= expectedLength else { break }

            frames.append(Data(buffer[0..<expectedLength]))
            buffer.removeFirst(expectedLength)
        }
        return frames
    }

    private func findCandidateStart() -> Int? {
        guard buffer.count >= 6 else { return nil }
        let lastStart = buffer.count - 6
        for start in 0...lastStart {
            if buffer[start + 3] == Self.realtimeCommand && buffer[start + 4] == Self.realtimeAddress {
                return start
            }
        }
        return nil
    }

    private func retainPossiblePrefix() {
        // A candidate can begin in the final five bytes and complete in the next notification.
        if buffer.count > 5 {
            buffer.removeFirst(buffer.count - 5)
        }
    }
}

/// Short name matching the Android feature's controller assembler terminology.
public typealias ControllerFrameAssembler = MotorControllerFrameAssembler
