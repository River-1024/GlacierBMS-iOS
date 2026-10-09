import Foundation

public final class BmsFrameAssembler {
    private var buffer = Data()
    private let maximumFrameLength: Int

    public init(maximumFrameLength: Int = 512) {
        self.maximumFrameLength = maximumFrameLength
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []

        while true {
            guard buffer.count >= 2 else { break }

            // Keep only a possible frame header at the front. This handles noise
            // and multiple frames in one notification without ambiguous Data ranges.
            if buffer[0] != 0x7E || buffer[1] != 0xA1 {
                if let nextHeader = buffer.dropFirst().firstIndex(of: 0x7E) {
                    buffer = Data(buffer[nextHeader...])
                } else {
                    buffer = buffer.last == 0x7E ? Data([0x7E]) : Data()
                }
                continue
            }

            guard buffer.count >= 6 else { break }
            let payloadLength = Int(buffer[5])
            let frameLength = 6 + payloadLength + 2
            guard frameLength >= 8, frameLength <= maximumFrameLength else {
                buffer.removeFirst(2)
                continue
            }
            guard buffer.count >= frameLength else { break }

            let candidate = Data(buffer.prefix(frameLength))
            if candidate[frameLength - 2] == 0xAA && candidate[frameLength - 1] == 0x55 {
                frames.append(candidate)
                buffer = Data(buffer.dropFirst(frameLength))
            } else {
                buffer.removeFirst(2)
            }
        }
        return frames
    }
}
