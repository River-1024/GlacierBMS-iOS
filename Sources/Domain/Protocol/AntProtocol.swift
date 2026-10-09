import Foundation

public enum AntProtocol {
    public static let queryCommand = Data([0x7E, 0xA1, 0x01, 0x00, 0x00, 0xBE, 0x18, 0x55, 0xAA, 0x55])

    public static func parseStatusResponse(_ data: Data, receivedAt: Date = Date()) -> BmsSnapshot? {
        guard data.count >= 100,
              data[0] == 0x7E, data[1] == 0xA1,
              data[2] == 0x11,
              data[data.count - 2] == 0xAA,
              data[data.count - 1] == 0x55 else { return nil }

        let declaredLength = Int(data[5])
        guard 6 + declaredLength + 2 <= data.count else { return nil }

        func u8(_ index: Int) -> Int { Int(data[index]) }
        func u16(_ index: Int) -> Int {
            Int(data[index]) | (Int(data[index + 1]) << 8)
        }
        func i16(_ index: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(index)))) }
        func u32(_ index: Int) -> UInt32 {
            UInt32(data[index]) |
                (UInt32(data[index + 1]) << 8) |
                (UInt32(data[index + 2]) << 16) |
                (UInt32(data[index + 3]) << 24)
        }
        func i32(_ index: Int) -> Int32 { Int32(bitPattern: u32(index)) }
        func has(_ index: Int, _ count: Int) -> Bool { index >= 0 && index + count <= data.count }

        let temperatureCount = u8(8)
        let cellCount = u8(9)
        guard temperatureCount <= 16, cellCount <= 64 else { return nil }

        var offset = 34
        guard has(offset, cellCount * 2) else { return nil }
        let cells = (0..<cellCount).map { index -> Int in
            u16(offset + index * 2)
        }
        offset += cellCount * 2

        guard has(offset, temperatureCount * 2 + 4 + 2 + 2 + 2) else { return nil }
        let temperatures = (0..<temperatureCount).map { index -> Int in
            i16(offset + index * 2)
        }
        offset += temperatureCount * 2
        let mosTemperature = i16(offset)
        let balancerTemperature = i16(offset + 2)
        offset += 4
        offset += 2 // protocol total voltage; cell sum remains the source of truth
        let current = Double(i16(offset)) * 0.1
        offset += 2
        let soc = Double(u16(offset))
        offset += 2

        var soh: Int?
        var chargeMOSOn: Bool?
        var dischargeMOSOn: Bool?
        var balanceStatus: Int?
        if has(offset, 6) {
            soh = u16(offset)
            chargeMOSOn = u8(offset + 2) != 0
            dischargeMOSOn = u8(offset + 3) != 0
            balanceStatus = u8(offset + 4)
            offset += 6
        }

        var capacityAh: Double = 0
        var remainingAh: Double = 0
        var power: Double?
        var runtime: UInt32?
        if has(offset, 20) {
            capacityAh = Double(u32(offset)) * 0.000001
            remainingAh = Double(u32(offset + 4)) * 0.000001
            _ = u32(offset + 8) // cycle capacity, not part of the first dashboard contract
            power = Double(i32(offset + 12))
            runtime = u32(offset + 16)
            offset += 20
        }

        var balanceMask: UInt32?
        if has(offset, 4) {
            balanceMask = u32(offset)
            offset += 4
        }

        var protocolVoltageDiff: Int?
        if has(offset, 12) {
            protocolVoltageDiff = u16(offset + 8)
            offset += 12
        }

        let statusCode = has(7, 1) ? u8(7) : nil
        let statusText: String
        switch statusCode {
        case 1: statusText = "待机"
        case 2: statusText = "充电中"
        case 3: statusText = "放电中"
        case 4: statusText = "休眠"
        case 5: statusText = "错误"
        default: statusText = "未知"
        }

        let dataEnd = min(data.count, 6 + declaredLength)
        let voltageDiff: Int?
        if let protocolVoltageDiff {
            voltageDiff = protocolVoltageDiff
        } else if let maximum = cells.max(), let minimum = cells.min() {
            voltageDiff = maximum - minimum
        } else {
            voltageDiff = nil
        }

        return BmsSnapshot(
            receivedAt: receivedAt,
            totalVoltage: Double(cells.reduce(0, +)) / 1000.0,
            current: current,
            soc: soc,
            capacityAh: capacityAh,
            remainingAh: remainingAh,
            temperatures: temperatures,
            mosTemperature: mosTemperature,
            balancerTemperature: balancerTemperature,
            cellVoltagesMillivolts: cells,
            soh: soh,
            power: power,
            runtimeSeconds: runtime,
            voltageDiffMillivolts: voltageDiff,
            chargeMOSOn: chargeMOSOn,
            dischargeMOSOn: dischargeMOSOn,
            balanceStatus: balanceStatus,
            balanceMask: balanceMask,
            statusCode: statusCode,
            statusText: statusText,
            frameLength: data.count,
            unparsedBytes: max(0, dataEnd - offset)
        )
    }
}
