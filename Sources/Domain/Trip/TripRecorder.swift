import Foundation

/// 行程记录器（领域层纯逻辑，不依赖 CoreLocation / CoreBluetooth）。
///
/// 设计约束（对应规划 §4 阶段 2 验收红线）：
/// 1. 锁屏/暂停区间的数据必须显式记为 `suspended` 段，不用旧值伪装实时。
/// 2. GPS 无效、BLE 断开、采样间隔超限一律产生 `gap` 段或丢弃样本，
///    不插值、不伪造里程与能耗。
/// 3. 前台/后台切换只产生 `foreground`/`background` 段边界，
///    始终是同一行程，不重复开始。
///
/// 能耗配对规则：相邻两个 BMS 功率样本的时间差 ≤ `maxBmsSampleInterval`
/// 才做 `功率 × Δt` 积分；首样本无前值、间隔超限（BLE 断开）一律跳过。
public struct TripRecorder: Sendable {
    public let maxLocationGap: TimeInterval
    public let maxBmsSampleInterval: TimeInterval
    public let maxHorizontalAccuracy: Double

    /// 当前状态。
    public private(set) var state: TripState = .idle
    /// 已闭合区间。
    public private(set) var segments: [TripSegment] = []
    /// 行程开始时间（`start` 之后有效）。
    public private(set) var startedAt: Date?

    /// 实时区间视图：闭合段 + 进行中段的即时快照（供 UI 展示实时统计，
    /// 不改变状态机语义；进行中段以后一刻为界临时闭合）。
    public var liveSegments: [TripSegment] {
        var result = segments
        if let open = openSegment {
            result.append(open.closed(at: Date()))
        }
        return result
    }

    struct OpenSegment: Sendable {
        var kind: TripSegmentKind
        var startedAt: Date
        var distanceMeters: Double = 0
        var energyWh: Double = 0
        var locationCount = 0
        var energySampleCount = 0
        var invalidLocationCount = 0

        func closed(at end: Date) -> TripSegment {
            TripSegment(
                kind: kind,
                startedAt: startedAt,
                endedAt: end,
                distanceMeters: distanceMeters,
                energyWh: energyWh,
                locationCount: locationCount,
                energySampleCount: energySampleCount,
                invalidLocationCount: invalidLocationCount
            )
        }
    }

    private var openSegment: OpenSegment?
    private var lastFix: GpsFix?
    private var lastEnergyTime: Date?
    private var lastPhase: TripSegmentKind = .foreground

    public init(
        maxLocationGap: TimeInterval = 10,
        maxBmsSampleInterval: TimeInterval = 5,
        maxHorizontalAccuracy: Double = 50
    ) {
        self.maxLocationGap = maxLocationGap
        self.maxBmsSampleInterval = maxBmsSampleInterval
        self.maxHorizontalAccuracy = maxHorizontalAccuracy
    }

    // MARK: - 生命周期

    /// 开始一段行程。`kind` 决定初始区间归属（前台/后台）。
    public mutating func start(at date: Date, kind: TripSegmentKind = .foreground) {
        guard state == .idle else { return }
        state = .recording
        startedAt = date
        lastPhase = kind == .background ? .background : .foreground
        openSegment = OpenSegment(kind: lastPhase, startedAt: date)
    }

    /// 前台/后台切换。同一行程内闭合旧段、开启新段，不产生缺口。
    public mutating func setPhase(_ kind: TripSegmentKind, at date: Date) {
        guard state == .recording,
              kind == .foreground || kind == .background,
              kind != lastPhase else { return }
        closeOpenSegment(at: date)
        lastPhase = kind
        openSegment = OpenSegment(kind: kind, startedAt: date)
    }

    /// 锁屏/用户暂停。暂停区间记为 `suspended` 段，持续到 `resume`。
    public mutating func suspend(at date: Date) {
        guard state == .recording else { return }
        closeOpenSegment(at: date)
        openSegment = OpenSegment(kind: .suspended, startedAt: date)
        state = .suspended
        // 暂停期间定位与 BMS 样本全部失效，恢复时重新配对。
        lastFix = nil
        lastEnergyTime = nil
    }

    /// 从暂停恢复：闭合暂停段，回到暂停前的前台/后台相位。
    public mutating func resume(at date: Date) {
        guard state == .suspended else { return }
        closeOpenSegment(at: date)
        openSegment = OpenSegment(kind: lastPhase, startedAt: date)
        state = .recording
    }

    /// 结束行程。返回不可变 `Trip`；重复调用返回 nil。
    @discardableResult
    public mutating func finish(at date: Date) -> Trip? {
        guard state == .recording || state == .suspended, let started = startedAt else { return nil }
        closeOpenSegment(at: date)
        let trip = Trip(startedAt: started, endedAt: date, segments: segments)
        state = .finished
        openSegment = nil
        lastFix = nil
        lastEnergyTime = nil
        return trip
    }

    // MARK: - 采样输入

    /// 摄入一次 GPS 定位。仅在 `recording` 状态处理。
    ///
    /// 规则：
    /// - 无效定位（精度超限/坐标非法）计入 `invalidLocationCount`，不动里程；
    /// - 与上一个有效定位的间隔 > `maxLocationGap` 时，在两者之间插入 `gap` 段，
    ///   间隔期间的里程不予追溯（不插值）；
    /// - 有效定位按球面距离累计（两端速度可信时优先用平均速度 × Δt）。
    public mutating func ingestLocation(_ fix: GpsFix) {
        guard state == .recording else { return }
        guard var segment = openSegment else { return }

        guard fix.isUsable(maxAccuracy: maxHorizontalAccuracy) else {
            segment.invalidLocationCount += 1
            openSegment = segment
            return
        }

        segment.locationCount += 1

        if let previous = lastFix {
            let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
            if dt > maxLocationGap {
                // 长间隔：闭合当前段并插入缺口段，缺口期间不追溯里程。
                segments.append(segment.closed(at: previous.timestamp))
                segments.append(
                    OpenSegment(kind: .gap, startedAt: previous.timestamp)
                        .closed(at: fix.timestamp)
                )
                openSegment = OpenSegment(kind: lastPhase, startedAt: fix.timestamp)
                lastFix = fix
                return
            }
            if dt > 0 {
                if previous.isSpeedValid && fix.isSpeedValid {
                    let averageSpeed = (previous.speed + fix.speed) / 2
                    segment.distanceMeters += max(0, averageSpeed * dt)
                } else {
                    segment.distanceMeters += max(0, haversineMeters(from: previous, to: fix))
                }
            }
        }
        lastFix = fix
        openSegment = segment
    }

    /// 摄入一次 BMS 功率采样（瓦）。仅在 `recording` 状态处理。
    ///
    /// 配对规则：首样本只登记不积分；与上一有效样本间隔 > `maxBmsSampleInterval`
    /// （BLE 断开/查询停摆）则重置配对基准，间隔期间的能耗记为缺口，不伪造。
    public mutating func ingestPowerWatts(_ watts: Double, at date: Date) {
        guard state == .recording else { return }
        guard var segment = openSegment else { return }

        if let previous = lastEnergyTime {
            let dt = date.timeIntervalSince(previous)
            if dt > 0 {
                if dt <= maxBmsSampleInterval {
                    segment.energyWh += watts * dt / 3600
                    segment.energySampleCount += 1
                    lastEnergyTime = date
                } else {
                    // 间隔超限：不补算，仅重置配对基准。
                    lastEnergyTime = date
                }
            }
        } else {
            lastEnergyTime = date
        }
        openSegment = segment
    }

    /// 便捷入口：按 `BmsSnapshot.receivedAt` 摄入功率（快照的 `power` 可为 nil）。
    public mutating func ingestSnapshot(_ snapshot: BmsSnapshot) {
        guard let power = snapshot.power else { return }
        ingestPowerWatts(power, at: snapshot.receivedAt)
    }

    // MARK: - 内部

    private mutating func closeOpenSegment(at date: Date) {
        guard let segment = openSegment else { return }
        segments.append(segment.closed(at: date))
        openSegment = nil
    }

    private func haversineMeters(from: GpsFix, to: GpsFix) -> Double {
        let radius = 6_371_000.0
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}
