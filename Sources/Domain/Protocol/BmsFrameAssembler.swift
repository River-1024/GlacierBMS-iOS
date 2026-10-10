import Foundation

/// ANT BMS 分片合包器：把 BLE Notify 到达的任意分片拼成完整帧。
///
/// 实现约束（2026-10-10 真机闪退教训，见 docs/MIGRATION_PLAN.md §11.0.1）：
/// 内部一律使用 `[UInt8]` 显式整数下标 + 自管游标，**不用 `Data` 切片语义、
/// 不用 Collection 泛型算法**（`dropFirst` / `firstIndex(of:)` / 切片下标）。
/// 原实现每个下标虽有守卫，仍在 iOS 27.2 Beta 上以
/// `EXC_BREAKPOINT` 崩溃于本函数（三份崩溃报告栈帧一致）；
/// 重写后所有读取点显式判界，任何输入形态均不 trap。
public final class BmsFrameAssembler {
    private var buffer: [UInt8] = []
    private let maximumFrameLength: Int

    public init(maximumFrameLength: Int = 512) {
        self.maximumFrameLength = maximumFrameLength
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public func append(_ chunk: Data) -> [Data] {
        buffer.append(contentsOf: chunk)
        var frames: [Data] = []
        var pos = 0

        while true {
            let remaining = buffer.count - pos
            guard remaining >= 2 else { break }

            // 帧头必须为 7E A1；不对齐则向前搜索下一个可能的帧头位置。
            if buffer[pos] != 0x7E || buffer[pos + 1] != 0xA1 {
                var nextHeader = -1
                for i in (pos + 1)..<buffer.count where buffer[i] == 0x7E {
                    nextHeader = i
                    break
                }
                if nextHeader >= 0 {
                    pos = nextHeader
                } else if buffer[buffer.count - 1] == 0x7E {
                    // 末字节可能是被截断的帧头，保留它。
                    pos = buffer.count - 1
                } else {
                    pos = buffer.count
                }
                continue
            }

            guard remaining >= 6 else { break }
            let payloadLength = Int(buffer[pos + 5])
            let frameLength = 6 + payloadLength + 2
            guard frameLength >= 8, frameLength <= maximumFrameLength else {
                // 声明长度非法：当前两字节不构成有效帧头，向前滑动。
                pos += 2
                continue
            }
            guard remaining >= frameLength else { break }

            let tail = pos + frameLength
            if buffer[tail - 2] == 0xAA && buffer[tail - 1] == 0x55 {
                frames.append(Data(buffer[pos..<tail]))
                pos = tail
            } else {
                // 尾标识不符：当前两字节不是真帧头，向前滑动。
                pos += 2
            }
        }

        if pos > 0 {
            buffer.removeFirst(min(pos, buffer.count))
        }
        return frames
    }
}
