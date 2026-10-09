import XCTest
@testable import GlacierBMSDomain

final class AntProtocolTests: XCTestCase {
    func testQueryCommandMatchesAndroidCapture() {
        XCTAssertEqual(AntProtocol.queryCommand, Data([0x7E, 0xA1, 0x01, 0x00, 0x00, 0xBE, 0x18, 0x55, 0xAA, 0x55]))
    }

    func testParsesRealStatusFrame() {
        let frame = makeFrame(cellCount: 20, temperatureCount: 2)
        let snapshot = AntProtocol.parseStatusResponse(frame)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.cellVoltagesMillivolts.count, 20)
        XCTAssertEqual(snapshot?.temperatures.count, 2)
        XCTAssertEqual(snapshot?.statusCode, 1)
    }

    func testParsesCurrentSOCPowerAtLockedOffsets() {
        // 20 单体 + 2 温度下的 0x11 帧布局：
        // 电流 @84（i16，0.1A）、SOC @86（u16，%）、功率 @100（i32，W）。
        let frame = makeFrame(cellCount: 20, temperatureCount: 2, currentA: 125, socPercent: 80, powerW: 1500)
        let snapshot = AntProtocol.parseStatusResponse(frame)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.current ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(snapshot?.soc ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(snapshot?.power ?? -1, 1500, accuracy: 0.001)
    }

    func testRejectsInvalidFrame() {
        XCTAssertNil(AntProtocol.parseStatusResponse(Data(repeating: 0, count: 180)))
    }

    private func makeFrame(cellCount: Int, temperatureCount: Int, currentA: Int = 0, socPercent: Int = 0, powerW: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 180)
        bytes[0] = 0x7E; bytes[1] = 0xA1; bytes[2] = 0x11
        bytes[5] = UInt8(bytes.count - 8)
        bytes[7] = 1; bytes[8] = UInt8(temperatureCount); bytes[9] = UInt8(cellCount)
        for cell in 0..<cellCount {
            let value = UInt16(3500 + cell)
            bytes[34 + cell * 2] = UInt8(value & 0xFF)
            bytes[35 + cell * 2] = UInt8(value >> 8)
        }
        let temperatureOffset = 34 + cellCount * 2
        for index in 0..<temperatureCount {
            let value = UInt16(bitPattern: Int16(25 + index))
            bytes[temperatureOffset + index * 2] = UInt8(value & 0xFF)
            bytes[temperatureOffset + index * 2 + 1] = UInt8(value >> 8)
        }
        let currentOffset = temperatureOffset + temperatureCount * 2 + 4 + 2
        let current = UInt16(clamping: currentA)
        bytes[currentOffset] = UInt8(current & 0xFF)
        bytes[currentOffset + 1] = UInt8(current >> 8)
        let socOffset = currentOffset + 2
        let soc = UInt16(clamping: socPercent)
        bytes[socOffset] = UInt8(soc & 0xFF)
        bytes[socOffset + 1] = UInt8(soc >> 8)
        let powerOffset = socOffset + 2 + 12
        let power = UInt32(clamping: powerW)
        bytes[powerOffset] = UInt8(power & 0xFF)
        bytes[powerOffset + 1] = UInt8((power >> 8) & 0xFF)
        bytes[powerOffset + 2] = UInt8((power >> 16) & 0xFF)
        bytes[powerOffset + 3] = UInt8((power >> 24) & 0xFF)
        bytes[bytes.count - 2] = 0xAA; bytes[bytes.count - 1] = 0x55
        return Data(bytes)
    }
}
