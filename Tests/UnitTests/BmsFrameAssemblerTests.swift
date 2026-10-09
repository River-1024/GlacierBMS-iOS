import XCTest
@testable import ANTuRideDomain

final class BmsFrameAssemblerTests: XCTestCase {
    func testReassemblesAcrossNotifications() {
        let frame = makeFrame(payloadLength: 8)
        let assembler = BmsFrameAssembler()
        XCTAssertTrue(assembler.append(Data(frame.prefix(5))).isEmpty)
        XCTAssertEqual(assembler.append(Data(frame.dropFirst(5))), [frame])
    }

    func testReassemblesMultipleFrames() {
        let first = makeFrame(payloadLength: 8)
        let second = makeFrame(payloadLength: 10)
        XCTAssertEqual(BmsFrameAssembler().append(first + second), [first, second])
    }

    func testDropsNoiseBeforeHeader() {
        let frame = makeFrame(payloadLength: 8)
        XCTAssertEqual(BmsFrameAssembler().append(Data([0x00, 0x01]) + frame), [frame])
    }

    private func makeFrame(payloadLength: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 6 + payloadLength + 2)
        bytes[0] = 0x7E; bytes[1] = 0xA1; bytes[2] = 0x11; bytes[5] = UInt8(payloadLength)
        bytes[bytes.count - 2] = 0xAA; bytes[bytes.count - 1] = 0x55
        return Data(bytes)
    }
}
