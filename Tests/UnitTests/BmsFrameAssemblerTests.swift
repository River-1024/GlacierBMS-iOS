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

    // MARK: - Fuzz（2026-10-10 真机 EXC_BREAKPOINT 崩溃后的回归防线）

    /// 确定性伪随机源：xorshift64，保证测试可复现且不依赖平台随机设施。
    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func below(_ bound: Int) -> Int { bound == 0 ? 0 : Int(next() % UInt64(bound)) }
    }

    func testFuzzRandomStreamsNeverTrapAndOnlyEmitWellFormedFrames() {
        var rng = SeededRandom(seed: 0x2026_1010)
        for iteration in 0..<200 {
            let assembler = BmsFrameAssembler()
            for _ in 0..<40 {
                let chunkLength = rng.below(64) // 含 0 字节块（真机崩溃输入形态）
                let chunk = (0..<chunkLength).map { _ in rng.byte() }
                let frames = assembler.append(Data(chunk))
                for frame in frames {
                    XCTAssertTrue(frame.count >= 8, "iteration \(iteration): 帧长不足")
                    XCTAssertTrue(frame.count <= 512, "iteration \(iteration): 帧超上限")
                    XCTAssertEqual(frame[frame.startIndex], 0x7E, "iteration \(iteration): 帧头错")
                    XCTAssertEqual(frame[frame.index(after: frame.startIndex)], 0xA1, "iteration \(iteration): 帧头错")
                    XCTAssertEqual(frame[frame.count - 2], 0xAA, "iteration \(iteration): 尾标识错")
                    XCTAssertEqual(frame[frame.count - 1], 0x55, "iteration \(iteration): 尾标识错")
                    XCTAssertEqual(frame.count, 8 + Int(frame[5]), "iteration \(iteration): 帧长与声明不符")
                }
            }
        }
    }

    func testFuzzFrameEmbeddedInNoiseIsRecovered() {
        var rng = SeededRandom(seed: 42)
        let frame = makeFrame(payloadLength: 12)
        for _ in 0..<100 {
            let noiseLength = rng.below(32)
            let noise = (0..<noiseLength).map { _ in rng.byte() }
            // 噪声可能碰巧包含 7E，导致切出多个/零个帧——只断言「不 trap 且帧合法」。
            let frames = BmsFrameAssembler().append(noise + frame)
            XCTAssertTrue(frames.contains(frame), "完整帧必须从噪声中被恢复")
            for produced in frames {
                XCTAssertEqual(produced[produced.count - 2], 0xAA)
                XCTAssertEqual(produced[produced.count - 1], 0x55)
            }
        }
    }

    func testZeroLengthChunksNeverTrap() {
        let assembler = BmsFrameAssembler()
        let frame = makeFrame(payloadLength: 8)
        XCTAssertTrue(assembler.append(Data()).isEmpty)
        XCTAssertTrue(assembler.append(Data()).isEmpty)
        XCTAssertEqual(assembler.append(Data(frame)), [frame])
        XCTAssertTrue(assembler.append(Data()).isEmpty)
    }

    func testByteByByteDeliveryReassemblesFrame() {
        let frame = makeFrame(payloadLength: 20)
        let assembler = BmsFrameAssembler()
        var produced: [Data] = []
        for byte in frame {
            produced += assembler.append(Data([byte]))
        }
        XCTAssertEqual(produced, [frame])
    }

    private func makeFrame(payloadLength: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 6 + payloadLength + 2)
        bytes[0] = 0x7E; bytes[1] = 0xA1; bytes[2] = 0x11; bytes[5] = UInt8(payloadLength)
        bytes[bytes.count - 2] = 0xAA; bytes[bytes.count - 1] = 0x55
        return Data(bytes)
    }
}
