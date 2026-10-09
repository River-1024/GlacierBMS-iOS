import Foundation

public final class BmsFrameAssembler {
    private var buffer = Data()
    private let maximumFrameLength: Int
    private let header = Data([0x7E, 0xA1])

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
            guard let headerIndex = buffer.range(of: header)?.lowerBound else {
                if buffer.last == 0x7E { buffer = Data([0x7E]) } else { buffer.removeAll(keepingCapacity: true) }
                break
            }
            if headerIndex > 0 { buffer.removeFirst(headerIndex) }
            guard buffer.count >= 6 else { break }

            let payloadLength = Int(buffer[5])
            let frameLength = 6 + payloadLength + 2
            guard frameLength >= 8, frameLength <= maximumFrameLength else {
                buffer.removeFirst(2)
                continue
            }
            guard buffer.count >= frameLength else { break }

            let candidate = buffer.prefix(frameLength)
            if candidate[frameLength - 2] == 0xAA && candidate[frameLength - 1] == 0x55 {
                frames.append(Data(candidate))
                buffer.removeFirst(frameLength)
            } else {
                buffer.removeFirst(2)
            }
        }
        return frames
    }
}
