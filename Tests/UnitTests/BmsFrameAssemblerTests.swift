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
                    // 头尾界定（§11.2）：合法产出 = 7E A1 头 / AA 55 尾 / 长度 ≥4 且 ≤512。
                    // 声明长度字段不可信（真机 174 字节帧声明 0xA4），不再断言帧长与 [5] 的关系。
                    XCTAssertTrue(frame.count >= 4, "iteration \(iteration): 帧长不足")
                    XCTAssertTrue(frame.count <= 512, "iteration \(iteration): 帧超上限")
                    XCTAssertEqual(frame[frame.startIndex], 0x7E, "iteration \(iteration): 帧头错")
                    XCTAssertEqual(frame[frame.index(after: frame.startIndex)], 0xA1, "iteration \(iteration): 帧头错")
                    XCTAssertEqual(frame[frame.count - 2], 0xAA, "iteration \(iteration): 尾标识错")
                    XCTAssertEqual(frame[frame.count - 1], 0x55, "iteration \(iteration): 尾标识错")
                }
            }
        }
    }

    func testFuzzFrameEmbeddedInNoiseIsRecovered() {
        var rng = SeededRandom(seed: 42)
        let frame = makeFrame(payloadLength: 12)
        for _ in 0..<100 {
            // 噪声排除 0x7E，避免碰巧形成假帧头把噪声并入产出帧（头尾界定语义）。
            var noise: [UInt8] = []
            while noise.count < rng.below(32) {
                let byte = rng.byte()
                if byte != 0x7E { noise.append(byte) }
            }
            let frames = BmsFrameAssembler().append(Data(noise) + frame)
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

    /// 真机回归（2026-10-10 §11.2）：状态帧实际 174 字节，[5] 声明 0xA4=164，
    /// 声明长度 ≠ 实际帧长。旧实现按声明长度校验尾标识导致 0 帧产出、页面空白。
    func testRealDeviceStatusFrameWithMismatchedDeclaredLengthIsDelivered() {
        // 真机形态：7E A1 11 00 00 A4 01 01 02 14 ...（20 串单体）... AA 55，共 174 字节。
        var bytes = [UInt8](repeating: 0, count: 174)
        bytes[0] = 0x7E; bytes[1] = 0xA1; bytes[2] = 0x11
        bytes[5] = 0xA4; bytes[7] = 0x01; bytes[8] = 0x02; bytes[9] = 0x14
        bytes[34] = 0x32; bytes[35] = 0x0E // 单体电压 3634 mV（真实日志样本）
        bytes[172] = 0xAA; bytes[173] = 0x55
        let frame = Data(bytes)

        XCTAssertEqual(frame.count, 6 + Int(frame[5]) + 4, "前置条件：声明长度与实际帧长差 2")
        XCTAssertEqual(BmsFrameAssembler().append(frame), [frame])
    }

    private func makeFrame(payloadLength: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 6 + payloadLength + 2)
        bytes[0] = 0x7E; bytes[1] = 0xA1; bytes[2] = 0x11; bytes[5] = UInt8(payloadLength)
        bytes[bytes.count - 2] = 0xAA; bytes[bytes.count - 1] = 0x55
        return Data(bytes)
    }
}
