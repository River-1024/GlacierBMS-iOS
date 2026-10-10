import Foundation

/// ANT BMS 分片合包器：把 BLE Notify 到达的任意分片拼成完整帧。
///
/// 帧界定规则（2026-10-10 §11.2，对齐 Android 参考实现）：
/// **头尾界定**——以 `7E A1` 为帧起点，扫到最近的 `AA 55` 即整段交付，
/// **不读取/不信任 [5] 声明长度字段**（真机固件该字段与实际帧长不符：
/// 状态帧声明 0xA4=164、实际 174 字节；查询回执声明 0xBE=190、实际 10 字节）。
/// 单帧超过 `maximumFrameLength` 判为坏帧，丢弃当前帧头重新同步。
///
/// 实现约束（2026-10-10 真机闪退教训，见 docs/MIGRATION_PLAN.md §11.0.1）：
/// 内部一律使用 `[UInt8]` 显式整数下标 + 自管游标，**不用 `Data` 切片语义、
/// 不用 Collection 泛型算法**（`dropFirst` / `firstIndex(of:)` / 切片下标）。
/// 所有读取点显式判界，任何输入形态均不 trap。
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
            guard remaining >= 4 else { break } // 最短合法形态 7E A1 AA 55

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

            // 头尾界定：从帧头之后搜索最近的 AA 55 尾标识。
            var tail = -1
            var oversized = false
            var j = pos + 2
            while j + 1 < buffer.count {
                if j + 2 - pos > maximumFrameLength {
                    oversized = true
                    break
                }
                if buffer[j] == 0xAA && buffer[j + 1] == 0x55 {
                    tail = j
                    break
                }
                j += 1
            }

            if tail >= 0 {
                frames.append(Data(buffer[pos..<(tail + 2)]))
                pos = tail + 2
            } else if oversized {
                // 超上限的坏帧：当前两字节不是真帧头，向前滑动重新同步。
                pos += 2
            } else {
                // 未找到完整尾标识，等待后续分片
                // （末字节为 AA 时已在缓冲中保留，可自然拼接成 AA 55）。
                break
            }
        }

        if pos > 0 {
            buffer.removeFirst(min(pos, buffer.count))
        }
        return frames
    }
}
