import Foundation

/// 安卓加速测试唯一测速渠道：控制器转速（RPM）换算车速。
public enum AccelerationSource: String, Codable, CaseIterable, Sendable {
    case rpm
}

public enum AccelerationPhase: String, Codable, Sendable {
    case armed, running, completed, partial, interrupted
    public var isActive: Bool { self == .armed || self == .running }
}

public enum AccelerationChannelState: String, Codable, Sendable {
    case waitingStill, ready, running, reached, invalid, unavailable
    public var isAccepting: Bool { self == .waitingStill || self == .ready || self == .running }
}

public enum AccelerationError: Error, Equatable {
    case invalidConfiguration, invalidTimestamp, sessionAlreadyActive
}

/// Values match Android RPM target/coefficient/sign contract. Validation occurs at start.
public struct AccelerationConfig: Codable, Equatable, Sendable {
    public static let defaultRPMCoefficient = 0.0782
    public var targetSpeedKmh: Double
    public var rpmKmhPerUnit: Double?
    public var rpmForwardSign: Int
    public var algorithmVersion: String

    public init(targetSpeedKmh: Double = 50, rpmKmhPerUnit: Double? = AccelerationConfig.defaultRPMCoefficient,
                rpmForwardSign: Int = 1,
                algorithmVersion: String = "rpm-acceleration-v1") {
        self.targetSpeedKmh = targetSpeedKmh
        self.rpmKmhPerUnit = rpmKmhPerUnit
        self.rpmForwardSign = rpmForwardSign
        self.algorithmVersion = algorithmVersion
    }

    public func validate() throws {
        guard targetSpeedKmh.isFinite, (10...200).contains(targetSpeedKmh),
              rpmForwardSign == 1 || rpmForwardSign == -1,
              rpmKmhPerUnit.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw AccelerationError.invalidConfiguration
        }
    }

    public var targetsKmh: [Double] {
        guard targetSpeedKmh.isFinite, (10...200).contains(targetSpeedKmh) else { return [] }
        return stride(from: 10.0, to: targetSpeedKmh, by: 10).map { $0 } + [targetSpeedKmh]
    }

    /// Missing calibration is unavailable, not a guessed wheel coefficient.
    public func rpmSpeedMps(rawRpm: Double) -> Double? {
        guard (try? validate()) != nil, let coefficient = rpmKmhPerUnit, rawRpm.isFinite else { return nil }
        let speed = rawRpm * coefficient * Double(rpmForwardSign) / 3.6
        return speed.isFinite ? speed : nil
    }
}

/// RPM样本质量；加速测试不接入 GPS、IMU 或融合渠道。
public struct AccelerationSampleQuality: Codable, Equatable, Sendable {
    public var isValid: Bool
    public var isMock: Bool
    public var timingAmbiguous: Bool
    public var reason: String?

    public init(isValid: Bool = true, isMock: Bool = false,
                timingAmbiguous: Bool = false, reason: String? = nil) {
        self.isValid = isValid
        self.isMock = isMock
        self.timingAmbiguous = timingAmbiguous
        self.reason = reason
    }
    public static let valid = AccelerationSampleQuality()
}

/// timestamp 是采集端的单调时钟；BLE 无硬件时钟时使用手机接收时间，不能宣称硬件测量时刻。
public struct AccelerationSpeedSample: Codable, Equatable, Sendable {
    public let source: AccelerationSource
    public let timestamp: TimeInterval
    public let speedMps: Double
    public let quality: AccelerationSampleQuality
    public let accelerationMps2: Double?

    public init(source: AccelerationSource, timestamp: TimeInterval, speedMps: Double,
                quality: AccelerationSampleQuality = .valid, accelerationMps2: Double? = nil) {
        self.source = source
        self.timestamp = timestamp
        self.speedMps = speedMps
        self.quality = quality
        self.accelerationMps2 = accelerationMps2
    }
    public var speedKmh: Double { speedMps * 3.6 }
}

public struct AccelerationCurrentSample: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let busCurrentA: Double
    public let phasePeakCurrentA: Double
    public let rawRpm: Int
    public let sequence: Int64
    public let timingAmbiguous: Bool

    public init(timestamp: TimeInterval, busCurrentA: Double, phasePeakCurrentA: Double,
                rawRpm: Int, sequence: Int64 = 0, timingAmbiguous: Bool = false) {
        self.timestamp = timestamp
        self.busCurrentA = busCurrentA
        self.phasePeakCurrentA = phasePeakCurrentA
        self.rawRpm = rawRpm
        self.sequence = sequence
        self.timingAmbiguous = timingAmbiguous
    }
}

public struct AccelerationSplit: Codable, Equatable, Sendable {
    public let targetSpeedKmh: Double
    public let crossedAt: TimeInterval
    public let cumulativeSeconds: Double
    public let segmentSeconds: Double
    public let distanceMeters: Double
}

public struct AccelerationChannelResult: Codable, Equatable, Sendable {
    public let source: AccelerationSource
    public let state: AccelerationChannelState
    public let startTimestamp: TimeInterval?
    public let startUncertaintyMs: Double?
    public let splits: [AccelerationSplit]
    public let reason: String?
    public let sampleCount: Int
    public let effectiveHz: Double
    public let maxGapMs: Double
    public let rejectedSampleCount: Int
    public let lastQualityWarning: String?
}

/// Persist snapshots with JSONEncoder/JSONDecoder. A saved active record is evidence,
/// not a resumable session: monotonic clocks must never be reused across app launches.
public struct AccelerationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAt: Date
    public let referenceTimestamp: TimeInterval
    public let config: AccelerationConfig
    public let phase: AccelerationPhase
    public let endedAt: Date?
    public let endReason: String?
    public let results: [AccelerationChannelResult]
    public let speedSamples: [AccelerationSpeedSample]
    public let currentSamples: [AccelerationCurrentSample]
    public let conditions: [String: String]

    public var isActive: Bool { phase.isActive }
    public func result(for source: AccelerationSource) -> AccelerationChannelResult? {
        results.first { $0.source == source }
    }
}
