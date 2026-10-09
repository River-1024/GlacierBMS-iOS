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

    func testRejectsInvalidFrame() {
        XCTAssertNil(AntProtocol.parseStatusResponse(Data(repeating: 0, count: 180)))
    }

    private func makeFrame(cellCount: Int, temperatureCount: Int) -> Data {
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
        bytes[bytes.count - 2] = 0xAA; bytes[bytes.count - 1] = 0x55
        return Data(bytes)
    }
}
