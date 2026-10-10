import Foundation

/// A single read-only motor-controller sample.
public struct ControllerSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let voltage: Double
    public let current: Double
    public let rpm: Int
    public let speed: Double
    public let throttle: Double
    public let brake: Double

    public init(
        timestamp: Date,
        voltage: Double,
        current: Double,
        rpm: Int,
        speed: Double,
        throttle: Double,
        brake: Double
    ) {
        self.timestamp = timestamp
        self.voltage = voltage
        self.current = current
        self.rpm = rpm
        self.speed = speed
        self.throttle = throttle
        self.brake = brake
    }
}

/// In-memory controller recording session. It deliberately has no UI or Bluetooth concerns.
public final class ControllerRecordSession: @unchecked Sendable {
    public static let csvHeader = "timestamp,voltage,current,rpm,speed,throttle,brake"

    private var recordedSamples: [ControllerSample] = []
    public private(set) var isFinished = false

    public init() {}

    public var samples: [ControllerSample] { recordedSamples }
    public var count: Int { recordedSamples.count }

    /// Appends only finite, ISO-8601-representable timestamps in strictly increasing order.
    /// Missing/non-finite measurements remain recordable and export as empty CSV cells.
    @discardableResult
    public func append(_ sample: ControllerSample) -> Bool {
        let seconds = sample.timestamp.timeIntervalSince1970
        // ISO-8601 CSV uses four-digit years (0001...9999); never format NaN/Inf dates.
        guard !isFinished, seconds.isFinite,
              seconds >= -62_135_596_800, seconds < 253_402_300_800 else { return false }
        if let last = recordedSamples.last, sample.timestamp <= last.timestamp { return false }
        recordedSamples.append(sample)
        return true
    }

    /// Closes the session and returns its chronological sample snapshot.
    @discardableResult
    public func finish() -> [ControllerSample] {
        isFinished = true
        return recordedSamples
    }

    /// Exports the recorded samples in chronological order as UTF-8-compatible CSV text.
    public func exportCSV() -> String {
        let rows = recordedSamples.map { sample in
            [
                csvTimestamp(sample.timestamp),
                csvNumber(sample.voltage),
                csvNumber(sample.current),
                String(sample.rpm),
                csvNumber(sample.speed),
                csvNumber(sample.throttle),
                csvNumber(sample.brake)
            ].map(csvEscape).joined(separator: ",")
        }
        return ([Self.csvHeader] + rows).joined(separator: "\n") + "\n"
    }

    private func csvTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func csvNumber(_ value: Double) -> String {
        // Double.description is locale-independent and avoids changing recorded precision.
        value.isFinite ? String(value) : ""
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Reassembles controller notifications using the Android protocol's `6 + LEN + 2` boundary.
/// The first three bytes are intentionally not interpreted; command/address at offsets 3/4
/// identify a real-time response and byte 5 declares the data-region length.
/// `0x0D` may occur anywhere in the payload; there is no delimiter/tail byte.
/// Reset on connect/disconnect, polling pause or query timeout, just like Android.
public final class MotorControllerFrameAssembler {
    public static let realtimeCommand = MotorControllerProtocol.realtimeCommand
    public static let realtimeAddress = MotorControllerProtocol.realtimeAddress

    private var buffer: [UInt8] = []
    private let maximumFrameLength: Int

    public init(maximumFrameLength: Int = 512) {
        self.maximumFrameLength = max(8, maximumFrameLength)
    }

    public var pendingByteCount: Int { buffer.count }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Returns complete frames; malformed, zero-length, or over-limit candidates are skipped safely.
    public func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(contentsOf: chunk)
        var frames: [Data] = []

        while true {
            guard let candidate = findCandidateStart() else {
                retainPossiblePrefix()
                break
            }

            if candidate > 0 {
                buffer.removeFirst(candidate)
            }
            guard buffer.count >= 6 else { break }

            let dataLength = Int(buffer[5])
            let expectedLength = MotorControllerProtocol.responseDataRegionOffset + dataLength +
                MotorControllerProtocol.checksumLength
            if dataLength == 0 || expectedLength > maximumFrameLength {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= expectedLength else { break }

            frames.append(Data(buffer[0..<expectedLength]))
            buffer.removeFirst(expectedLength)
        }
        return frames
    }

    private func findCandidateStart() -> Int? {
        guard buffer.count >= 6 else { return nil }
        let lastStart = buffer.count - 6
        for start in 0...lastStart {
            if buffer[start + 3] == Self.realtimeCommand && buffer[start + 4] == Self.realtimeAddress {
                return start
            }
        }
        return nil
    }

    private func retainPossiblePrefix() {
        // A candidate can begin in the final five bytes and complete in the next notification.
        if buffer.count > 5 {
            buffer.removeFirst(buffer.count - 5)
        }
    }
}

/// Short name matching the Android feature's controller assembler terminology.
public typealias ControllerFrameAssembler = MotorControllerFrameAssembler
