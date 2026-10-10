import Foundation

/// All confirmed real-time fields, decoded independently of BLE and recording/UI concerns.
public struct MotorControllerTelemetry: Equatable, Sendable {
    public let controllerVoltageV: Double
    public let busCurrentA: Double
    public let rpm: Int
    public let controllerTemperatureC: Int
    public let motorTemperatureC: Int
    public let phasePeakCurrentA: Double
    public let throttleVoltageV: Double
    public let runStateCode: Int
    public let gear: Int
    public let controllerStateBits: Int
    public let faultBits: Int
    public let portStatusBits: Int
    public let givenIqA: Double
    public let feedbackIqA: Double
    public let givenIdA: Double
    public let fieldWeakeningA: Double
    public let historyFaultBits: Int
    /// LEN=0x1D omits this field. Use nil, not zero or Android's NaN sentinel.
    public let linearBrakeVoltageV: Double?

    public var runStateText: String {
        let names = ["空闲", "启动", "参数设置", "运行", "停止", "等待", "故障"]
        return names.indices.contains(runStateCode) ? names[runStateCode] : "未知"
    }

    public var faultSummary: String {
        guard faultBits != 0 else { return "无故障" }
        let names = [
            "霍尔故障", "硬件过流", "相过流", "过压", "欠压", "转把故障", "控制器过温",
            "电机过温", "堵转保护", "缺相保护", "Mosfet故障", "相传感器偏置故障",
            "母线传感器偏置故障", "控制器温度传感器故障", "电机温度传感器故障"
        ]
        return (0..<16).compactMap { bit -> String? in
            guard faultBits & (1 << bit) != 0 else { return nil }
            return bit < names.count ? names[bit] : "未知故障位\(bit)"
        }.joined(separator: "、")
    }
}

public enum MotorControllerFrameError: Equatable, Sendable {
    case frameTooShort
    case commandMismatch
    case addressMismatch
    case lengthMismatch
    case frameLengthMismatch
}

public enum MotorControllerParseResult: Equatable, Sendable {
    case valid(MotorControllerTelemetry)
    case invalid(MotorControllerFrameError)
}

/// Read-only port of Android protocol/MotorControllerProtocol.kt.
/// No generic opcode/address writer: the only command is the real-time query.
public enum MotorControllerProtocol {
    public static let realtimeCommand: UInt8 = 0x24
    public static let realtimeAddress: UInt8 = 0x01
    public static let responseDataRegionOffset = 6
    public static let checksumLength = 2
    public static let minimumResponseDataLength = 0x1D
    public static let realtimeDataLength = 0x1F
    public static let responseMinimumLength = responseDataRegionOffset + minimumResponseDataLength + checksumLength

    /// A8 02 01 24 01 1F, followed by SUM1=T[low], SUM2=R[255-low].
    /// Sum excludes A8 and the two checksum bytes. Data provides value-copy semantics.
    public static func realtimeMonitorCommand() -> Data {
        let payload: [UInt8] = [0x02, 0x01, realtimeCommand, realtimeAddress, UInt8(realtimeDataLength)]
        let low = payload.reduce(0) { ($0 + Int($1)) & 0xFF }
        return Data([0xA8] + payload + [tTable[low], rTable[0xFF - low]])
    }

    /// Response prefix bytes 0...2 and checksum contents are deliberately not validated,
    /// matching Android. Only command, address, supported LEN and exact size are checked.
    public static func parseRealtimeResponse(_ frame: Data) -> MotorControllerParseResult {
        // Copy to zero-based bytes; Data slices can otherwise retain a nonzero startIndex.
        let bytes = [UInt8](frame)
        guard bytes.count >= responseDataRegionOffset else { return .invalid(.frameTooShort) }
        guard bytes[3] == realtimeCommand else { return .invalid(.commandMismatch) }
        guard bytes[4] == realtimeAddress else { return .invalid(.addressMismatch) }
        let length = Int(bytes[5])
        guard length == minimumResponseDataLength || length == realtimeDataLength else {
            return .invalid(.lengthMismatch)
        }
        let expected = responseDataRegionOffset + length + checksumLength
        guard bytes.count >= expected else { return .invalid(.frameTooShort) }
        guard bytes.count == expected else { return .invalid(.frameLengthMismatch) }

        func u8(_ offset: Int) -> Int { Int(bytes[responseDataRegionOffset + offset]) }
        func u16(_ offset: Int) -> Int { u8(offset) | (u8(offset + 1) << 8) }
        func i16(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(offset)))) }
        let gearAndRunState = u8(12)
        return .valid(MotorControllerTelemetry(
            controllerVoltageV: Double(i16(0)) / 10.0,
            busCurrentA: Double(i16(2)) / 10.0,
            rpm: i16(4),
            controllerTemperatureC: u8(6) - 55,
            motorTemperatureC: u8(7) - 55,
            phasePeakCurrentA: Double(u16(8)) / 10.0,
            throttleVoltageV: Double(u16(10)) / 100.0,
            runStateCode: gearAndRunState >> 4,
            gear: gearAndRunState & 0x0F,
            controllerStateBits: u16(13),
            faultBits: u16(15),
            portStatusBits: u16(17),
            givenIqA: Double(i16(19)) / 10.0,
            feedbackIqA: Double(i16(21)) / 10.0,
            givenIdA: Double(i16(23)) / 10.0,
            fieldWeakeningA: Double(i16(25)) / 10.0,
            historyFaultBits: u16(27),
            linearBrakeVoltageV: length == realtimeDataLength ? Double(u16(29)) / 100.0 : nil
        ))
    }

    // Exact 256-entry tables from the parent Android protocol; not CRC or a delimiter.
    private static let tTable: [UInt8] = [
        179, 165, 196, 51, 108, 98, 15, 10, 5, 127, 69, 2, 141, 217, 157, 12,
        127, 19, 253, 0, 162, 232, 5, 146, 46, 191, 79, 131, 48, 128, 245, 20,
        47, 167, 84, 192, 16, 151, 16, 42, 55, 48, 89, 85, 239, 163, 108, 19,
        12, 133, 92, 192, 207, 35, 18, 47, 9, 22, 146, 229, 131, 23, 129, 133,
        158, 20, 228, 140, 55, 131, 43, 62, 205, 246, 110, 225, 230, 239, 246, 40,
        174, 246, 255, 242, 226, 234, 188, 53, 236, 149, 156, 52, 80, 130, 204, 249,
        70, 19, 253, 255, 168, 206, 103, 47, 15, 248, 14, 13, 58, 101, 68, 52,
        175, 142, 111, 0, 164, 228, 12, 138, 31, 100, 244, 217, 93, 108, 222, 86,
        113, 205, 38, 129, 45, 33, 205, 227, 69, 95, 192, 67, 178, 172, 93, 29,
        85, 116, 51, 80, 221, 186, 9, 23, 234, 172, 34, 58, 114, 123, 192, 134,
        101, 105, 231, 122, 140, 36, 99, 67, 183, 82, 13, 235, 23, 109, 73, 205,
        233, 209, 211, 76, 84, 19, 188, 196, 149, 149, 175, 193, 89, 87, 121, 111,
        106, 16, 200, 82, 142, 126, 51, 55, 173, 250, 123, 107, 49, 79, 17, 42,
        178, 204, 216, 90, 211, 152, 43, 122, 103, 70, 34, 213, 217, 169, 17, 251,
        202, 234, 82, 113, 251, 215, 69, 168, 110, 126, 148, 44, 200, 251, 188, 30,
        250, 142, 201, 228, 32, 241, 96, 31, 169, 232, 3, 221, 185, 25, 145, 17,
    ]

    private static let rTable: [UInt8] = [
        39, 203, 5, 153, 7, 109, 150, 188, 87, 140, 74, 173, 160, 158, 143, 175,
        104, 32, 188, 79, 86, 45, 81, 153, 151, 79, 128, 139, 127, 149, 237, 202,
        116, 230, 179, 148, 8, 148, 167, 246, 101, 52, 224, 63, 238, 174, 119, 180,
        35, 144, 139, 133, 197, 168, 136, 0, 59, 209, 169, 5, 53, 13, 188, 186,
        143, 212, 38, 127, 120, 172, 38, 37, 211, 250, 94, 90, 221, 24, 143, 104,
        17, 167, 164, 32, 73, 39, 242, 16, 37, 197, 190, 253, 176, 115, 255, 141,
        65, 62, 102, 67, 160, 220, 156, 176, 106, 133, 203, 232, 183, 5, 95, 52,
        249, 14, 14, 6, 40, 210, 21, 50, 28, 209, 197, 90, 58, 240, 63, 170,
        82, 204, 124, 198, 200, 77, 144, 1, 242, 126, 47, 208, 194, 156, 112, 126,
        165, 109, 209, 33, 170, 210, 123, 204, 231, 160, 200, 6, 25, 172, 3, 123,
        138, 37, 111, 242, 56, 39, 138, 127, 51, 140, 146, 250, 71, 6, 73, 175,
        219, 107, 246, 87, 25, 79, 172, 72, 79, 216, 206, 232, 149, 206, 211, 103,
        177, 242, 71, 174, 55, 145, 18, 146, 245, 88, 253, 78, 141, 106, 114, 48,
        100, 176, 131, 146, 187, 112, 47, 12, 28, 34, 224, 232, 248, 127, 55, 214,
        142, 218, 12, 225, 14, 179, 177, 162, 255, 138, 119, 180, 222, 241, 116, 104,
        8, 229, 131, 185, 218, 94, 139, 130, 22, 37, 5, 238, 136, 230, 184, 48,
    ]
}
