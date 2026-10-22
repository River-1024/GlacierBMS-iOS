import ActivityKit
import Foundation

/// 骑行实时活动的静态属性与动态状态。
///
/// **位置约束**：本文件必须留在 `Sources/LiveActivity`，不能放进 `Sources/Domain`。
/// `Package.swift` 以 macOS 平台编译 Domain 包，`import ActivityKit` 会让
/// `swift test` 在 macOS 上直接失败。
///
/// **可见性约束**：App 与 Widget extension 是两个独立 module，
/// 所有类型与成员必须 `public`，否则 `Activity.request` 与
/// `ActivityConfiguration(for:)` 无法在两侧识别同一活动类型。
///
/// **体积约束**：`ContentState` 每次更新都会整份序列化，上限 4KB。
/// 只放聚合标量，绝不放单体电压数组或行程采样点。
public struct RideActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 速度（km/h）；`nil` 表示无有效定位，展示为 `--`，不显示 0。
        public var speedKmh: Double?
        /// SOC 百分比。
        public var socPercent: Double?
        /// 功率（W），充电为负。
        public var powerWatts: Double?
        /// 本次行程累计里程（米）。
        public var distanceMeters: Double
        public var freshness: Freshness
        public var isCharging: Bool
        /// 数据来自本地直连还是云端回填。锁屏上必须可区分。
        public var source: Source

        public init(
            speedKmh: Double? = nil,
            socPercent: Double? = nil,
            powerWatts: Double? = nil,
            distanceMeters: Double = 0,
            freshness: Freshness = .noData,
            isCharging: Bool = false,
            source: Source = .local
        ) {
            self.speedKmh = speedKmh
            self.socPercent = socPercent
            self.powerWatts = powerWatts
            self.distanceMeters = distanceMeters
            self.freshness = freshness
            self.isCharging = isCharging
            self.source = source
        }

        /// 数据新鲜度。`stale` / `noData` 必须显式展示，不得把旧值当作实时值。
        public enum Freshness: String, Codable, Hashable {
            case fresh
            case stale
            case noData

            /// 锁屏与展开态的说明文案；`nil` 表示不显示。
            public var note: String? {
                switch self {
                case .fresh: return nil
                case .stale: return "数据已过期"
                case .noData: return "无有效数据"
                }
            }
        }

        public enum Source: String, Codable, Hashable {
            case local
            case remote

            public var label: String {
                switch self {
                case .local: return "本地"
                case .remote: return "云端"
                }
            }
        }
    }

    public let tripID: UUID
    public let startedAt: Date
    /// 是否在紧凑态显示速度。由 App 在创建活动时决定，避免 extension 读共享偏好。
    public let showsSpeed: Bool

    public init(tripID: UUID, startedAt: Date, showsSpeed: Bool = true) {
        self.tripID = tripID
        self.startedAt = startedAt
        self.showsSpeed = showsSpeed
    }
}
