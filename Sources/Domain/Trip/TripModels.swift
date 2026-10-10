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
        guard horizontalAccuracy >= 0, horizontalAccuracy <= maxAccuracy else { return false }
        return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    /// 速度是否可信：非负（CoreLocation 约定负值为无效）。
    public var isSpeedValid: Bool { speed >= 0 }
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

    public init(
        kind: TripSegmentKind,
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        energyWh: Double,
        locationCount: Int,
        energySampleCount: Int,
        invalidLocationCount: Int
    ) {
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.energyWh = energyWh
        self.locationCount = locationCount
        self.energySampleCount = energySampleCount
        self.invalidLocationCount = invalidLocationCount
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
