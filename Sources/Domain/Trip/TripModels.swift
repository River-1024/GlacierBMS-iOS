import Foundation

/// 单次 GPS 定位采样。领域层不直接依赖 CoreLocation，
/// 由采集层把 `CLLocation` 转换为本结构后喂给行程记录器。
public struct GpsFix: Equatable, Codable, Sendable {
    public let timestamp: Date
    public let latitude: Double
    public let longitude: Double
    /// 米/秒；CoreLocation 对无效速度返回负值，本层保持原值并配合 `isSpeedValid` 判定。
    public let speed: Double
    /// 水平精度（米）；`accuracy < 0` 表示无效。
    public let horizontalAccuracy: Double

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        speed: Double,
        horizontalAccuracy: Double
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
    }
}

extension GpsFix {
    /// 定位是否可用于里程累计：坐标合法且水平精度优于阈值。
    public func isUsable(maxAccuracy: Double) -> Bool {
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0, horizontalAccuracy <= maxAccuracy else { return false }
        return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    /// 速度是否可信：非负（CoreLocation 约定负值为无效）。
    public var isSpeedValid: Bool { speed.isFinite && speed >= 0 }
}

/// 行程区间标记。验收红线要求前台/后台/暂停/数据缺口四类必须显式区分，
/// 不允许用旧值或插值填补缺口。
public enum TripSegmentKind: String, Equatable, Sendable, CaseIterable, Codable {
    case foreground
    case background
    case suspended
    case gap
}

/// 行程区间。创建时即闭合（带起止时间），不可变。
public struct TripSegment: Equatable, Codable, Sendable {
    public let kind: TripSegmentKind
    public let startedAt: Date
    public let endedAt: Date
    /// 区间内累计里程（米）。
    public let distanceMeters: Double
    /// 区间内净能耗（瓦时，充电为负）；缺口/暂停区间恒为 0。
    public let energyWh: Double
    /// 有效 GPS 定位点数。
    public let locationCount: Int
    /// 参与能耗累计的 BMS 采样点数。
    public let energySampleCount: Int
    /// 被丢弃的无效定位点数（精度超限/坐标非法）。
    public let invalidLocationCount: Int
    /// nil 表示旧档案没有逐点证据；新段使用数组（可为空）。
    public let samples: [TripSample]?

    public init(
        kind: TripSegmentKind,
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        energyWh: Double,
        locationCount: Int,
        energySampleCount: Int,
        invalidLocationCount: Int,
        samples: [TripSample]? = nil
    ) {
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.energyWh = energyWh
        self.locationCount = locationCount
        self.energySampleCount = energySampleCount
        self.invalidLocationCount = invalidLocationCount
        self.samples = samples
    }
}

/// 行程状态机状态。
public enum TripState: Equatable, Sendable {
    case idle
    case recording
    case suspended
    case finished
}

/// 一次完整行程。
public struct Trip: Equatable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let segments: [TripSegment]

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, segments: [TripSegment]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
    }

    /// 点保存在段内，保持现有 Services 按 segments 重建/保存行程的语义。
    public var samples: [TripSample] { segments.flatMap { $0.samples ?? [] } }

    /// 全行程累计里程（米）。缺口/暂停区间不计里程。
    public var totalDistanceMeters: Double {
        segments.reduce(0) { $0 + $1.distanceMeters }
    }

    /// 全行程净能耗（瓦时）。
    public var totalEnergyWh: Double {
        segments.reduce(0) { $0 + $1.energyWh }
    }

    /// 记录跨度（秒）。
    public var durationSeconds: TimeInterval {
        (endedAt ?? segments.last?.endedAt ?? startedAt).timeIntervalSince(startedAt)
    }
}


/// 一次输入事件，不把异步 GPS/BMS 的旧值拼成“同时有效”的采样。
/// nil 有效性表示该事件未采集此来源；false 表示来源明确无效。
/// 积分证据属于 (timestamp - intervalSeconds, timestamp]，首点/断点为 nil。
public struct TripSample: Equatable, Codable, Sendable {
    public let timestamp: Date
    public let gpsValid: Bool?
    /// 是否可作为能耗来源（功率缺失/字段无效为 false）；nil 表示非 BMS 事件。
    public let bmsValid: Bool?
    public let latitude: Double?
    public let longitude: Double?
    public let speedMetersPerSecond: Double?
    public let powerWatts: Double?
    public let voltageVolts: Double?
    public let currentAmps: Double?
    public let locationIntervalSeconds: TimeInterval?
    public let distanceMeters: Double?
    public let energyIntervalSeconds: TimeInterval?
    public let energyWh: Double?

    public init(
        timestamp: Date, gpsValid: Bool? = nil, bmsValid: Bool? = nil,
        latitude: Double? = nil, longitude: Double? = nil,
        speedMetersPerSecond: Double? = nil, powerWatts: Double? = nil,
        voltageVolts: Double? = nil, currentAmps: Double? = nil,
        locationIntervalSeconds: TimeInterval? = nil, distanceMeters: Double? = nil,
        energyIntervalSeconds: TimeInterval? = nil, energyWh: Double? = nil
    ) {
        self.timestamp = timestamp
        self.gpsValid = gpsValid
        self.bmsValid = bmsValid
        self.latitude = latitude
        self.longitude = longitude
        self.speedMetersPerSecond = speedMetersPerSecond
        self.powerWatts = powerWatts
        self.voltageVolts = voltageVolts
        self.currentAmps = currentAmps
        self.locationIntervalSeconds = locationIntervalSeconds
        self.distanceMeters = distanceMeters
        self.energyIntervalSeconds = energyIntervalSeconds
        self.energyWh = energyWh
    }
}

public enum TripMetric: String, CaseIterable, Hashable, Sendable {
    case speed, power, voltage, current

    public func value(in sample: TripSample) -> Double? {
        let value: Double?
        switch self {
        case .speed:
            guard sample.gpsValid == true,
                  let speed = sample.speedMetersPerSecond, speed >= 0 else { return nil }
            value = speed * 3.6
        case .power: value = sample.bmsValid == true ? sample.powerWatts : nil
        case .voltage: value = sample.bmsValid == true ? sample.voltageVolts : nil
        case .current: value = sample.bmsValid == true ? sample.currentAmps : nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// 固定墙钟窗口；覆盖分母包含暂停/缺口，末窗按实际剩余时长计算。
/// 无证据用 nil，真实零耗电保留 0。Wh/km 仅使用 GPS/BMS 共同覆盖部分。
public struct TripWindowSummary: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let gpsCoveredSeconds: TimeInterval
    public let bmsCoveredSeconds: TimeInterval
    public let jointlyCoveredSeconds: TimeInterval
    public let distanceMeters: Double?
    public let energyWh: Double?
    public let jointDistanceMeters: Double?
    public let jointEnergyWh: Double?

    public var durationSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var gpsCoverageRatio: Double { ratio(gpsCoveredSeconds) }
    public var bmsCoverageRatio: Double { ratio(bmsCoveredSeconds) }
    public var coverageRatio: Double { ratio(jointlyCoveredSeconds) }
    public var averageSpeedKmh: Double? {
        guard gpsCoveredSeconds > 0, let distanceMeters else { return nil }
        return distanceMeters / gpsCoveredSeconds * 3.6
    }
    public var averagePowerWatts: Double? {
        guard bmsCoveredSeconds > 0, let energyWh else { return nil }
        return energyWh / bmsCoveredSeconds * 3600
    }
    public var whPerKm: Double? {
        guard let jointDistanceMeters, jointDistanceMeters > 0, let jointEnergyWh else { return nil }
        return jointEnergyWh / (jointDistanceMeters / 1000)
    }
    private func ratio(_ seconds: TimeInterval) -> Double {
        durationSeconds > 0 ? min(1, max(0, seconds / durationSeconds)) : 0
    }
}

extension Trip {
    public static let supportedWindowMinutes = [1, 3, 5, 10]

    /// 每一组都是独立曲线；不跨段、无效点、缺少配对证据或倒序时间连线。
    /// 与摘要共享记录器持久化的配对证据，不硬编码记录器的可配置采样阈值。
    public func chartSegments(for metric: TripMetric) -> [[TripSample]] {
        var result: [[TripSample]] = []
        for segment in segments where segment.kind == .foreground || segment.kind == .background {
            var line: [TripSample] = []
            for sample in segment.samples ?? [] {
                let sourcePresent = metric == .speed ? sample.gpsValid != nil : sample.bmsValid != nil
                guard sourcePresent else { continue }
                guard sample.timestamp >= segment.startedAt, sample.timestamp <= segment.endedAt,
                      metric.value(in: sample) != nil else {
                    if !line.isEmpty { result.append(line); line = [] }
                    continue
                }
                if let previous = line.last {
                    let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
                    let paired = metric == .speed ? sample.locationIntervalSeconds : sample.energyIntervalSeconds
                    let continuous = paired.map { $0.isFinite && abs($0 - dt) <= 0.000001 } ?? false
                    if dt <= 0 || !continuous {
                        result.append(line)
                        line = []
                    }
                }
                line.append(sample)
            }
            if !line.isEmpty { result.append(line) }
        }
        return result
    }

    /// 越窗积分按已记录区间的时间比例分摊，不外推首尾或填补缺口。
    /// 旧档案即使有段总计，缺少点积分证据仍为零覆盖，绝不均摊整段总计。
    public func windowSummaries(minutes: Int = 3) -> [TripWindowSummary] {
        guard Self.supportedWindowMinutes.contains(minutes) else { return [] }
        let end = endedAt ?? segments.last?.endedAt ?? startedAt
        let duration = end.timeIntervalSince(startedAt)
        let width = Double(minutes * 60)
        guard duration.isFinite, duration > 0, ceil(duration / width) <= 100_000 else { return [] }
        let count = Int(ceil(duration / width))
        var gps = Array(repeating: WindowTotal(), count: count)
        var bms = gps
        var jointGps = gps
        var jointBms = gps
        let locations = evidence(energy: false, end: end)
        let energies = evidence(energy: true, end: end)
        func distribute(_ span: SampleInterval, into totals: inout [WindowTotal]) {
            let first = max(0, Int(floor(span.start.timeIntervalSince(startedAt) / width)))
            let last = min(count - 1, Int(ceil(span.end.timeIntervalSince(startedAt) / width)) - 1)
            guard first <= last else { return }
            for index in first...last {
                let start = startedAt.addingTimeInterval(Double(index) * width)
                let finish = min(end, start.addingTimeInterval(width))
                let overlap = min(finish, span.end).timeIntervalSince(max(start, span.start))
                guard overlap > 0 else { continue }
                totals[index].seconds += overlap
                totals[index].value += span.value * overlap / span.end.timeIntervalSince(span.start)
            }
        }
        for span in locations { distribute(span, into: &gps) }
        for span in energies { distribute(span, into: &bms) }
        var i = 0
        var j = 0
        while i < locations.count && j < energies.count {
            let location = locations[i]
            let energy = energies[j]
            let start = max(location.start, energy.start)
            let finish = min(location.end, energy.end)
            if finish > start {
                let seconds = finish.timeIntervalSince(start)
                distribute(SampleInterval(start: start, end: finish,
                    value: location.value * seconds / location.end.timeIntervalSince(location.start)), into: &jointGps)
                distribute(SampleInterval(start: start, end: finish,
                    value: energy.value * seconds / energy.end.timeIntervalSince(energy.start)), into: &jointBms)
            }
            if location.end <= energy.end { i += 1 }
            if energy.end <= location.end { j += 1 }
        }
        return (0..<count).map { index in
            let start = startedAt.addingTimeInterval(Double(index) * width)
            return TripWindowSummary(startedAt: start, endedAt: min(end, start.addingTimeInterval(width)),
                gpsCoveredSeconds: gps[index].seconds, bmsCoveredSeconds: bms[index].seconds,
                jointlyCoveredSeconds: jointGps[index].seconds,
                distanceMeters: gps[index].measuredValue, energyWh: bms[index].measuredValue,
                jointDistanceMeters: jointGps[index].measuredValue, jointEnergyWh: jointBms[index].measuredValue)
        }
    }

    private func evidence(energy: Bool, end: Date) -> [SampleInterval] {
        var result: [SampleInterval] = []
        var cursor = startedAt
        for segment in segments where segment.kind == .foreground || segment.kind == .background {
            for sample in segment.samples ?? [] {
                let valid = energy ? sample.bmsValid : sample.gpsValid
                let interval = energy ? sample.energyIntervalSeconds : sample.locationIntervalSeconds
                let value = energy ? sample.energyWh : sample.distanceMeters
                guard valid == true, let seconds = interval, seconds.isFinite, seconds > 0,
                      let amount = value, amount.isFinite, energy || amount >= 0 else { continue }
                let start = sample.timestamp.addingTimeInterval(-seconds)
                guard start >= cursor, start >= segment.startedAt, sample.timestamp <= segment.endedAt,
                      sample.timestamp <= end else { continue }
                result.append(SampleInterval(start: start, end: sample.timestamp, value: amount))
                cursor = sample.timestamp
            }
        }
        return result
    }
}

private struct SampleInterval {
    let start: Date
    let end: Date
    let value: Double
}

private struct WindowTotal {
    var seconds: TimeInterval = 0
    var value: Double = 0
    var measuredValue: Double? { seconds > 0 ? value : nil }
}
