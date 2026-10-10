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
/// 才做右端矩形 `本次功率 × Δt / 3600` 积分（非梯形）；
/// 首样本无前值、间隔超限（BLE 断开）一律跳过。
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
        var samples: [TripSample] = []

        func closed(at end: Date) -> TripSegment {
            TripSegment(
                kind: kind,
                startedAt: startedAt,
                endedAt: end,
                distanceMeters: distanceMeters,
                energyWh: energyWh,
                locationCount: locationCount,
                energySampleCount: energySampleCount,
                invalidLocationCount: invalidLocationCount,
                samples: samples
            )
        }
    }

    private var openSegment: OpenSegment?
    private var lastFix: GpsFix?
    private var lastEnergyTime: Date?
    private var lastLocationInputTime: Date?
    private var lastBmsInputTime: Date?
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
        // 不跨相位边界配对，避免缺口回溯到旧段并生成倒置/重叠区间。
        lastFix = nil
        lastEnergyTime = nil
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

    /// GPS 无效点仍保存有效性证据，并清除里程配对基准。
    /// 倒序/重复输入不参与采样；长缺口不补算，也不把 BMS 配对带入新段。
    public mutating func ingestLocation(_ fix: GpsFix) {
        guard state == .recording, var segment = openSegment,
              fix.timestamp.timeIntervalSinceReferenceDate.isFinite,
              fix.timestamp >= segment.startedAt,
              lastLocationInputTime.map({ fix.timestamp > $0 }) ?? true else { return }
        // 转移段的数组所有权，避免每次 append 对长行程样本做整数组复制。
        openSegment = nil
        lastLocationInputTime = fix.timestamp
        let valid = fix.isUsable(maxAccuracy: maxHorizontalAccuracy)
        var interval: TimeInterval?
        var distance: Double?
        if !valid {
            segment.invalidLocationCount += 1
            lastFix = nil
        } else {
            if let previous = lastFix {
                let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
                if dt > maxLocationGap {
                    // 不回溯覆盖已入段的异步 BMS 点；缺口从最后已记录事件开始。
                    let boundary = max(previous.timestamp, segment.samples.map(\.timestamp).max() ?? segment.startedAt)
                    if boundary <= fix.timestamp {
                        segments.append(segment.closed(at: boundary))
                        segments.append(OpenSegment(kind: .gap, startedAt: boundary).closed(at: fix.timestamp))
                        segment = OpenSegment(kind: lastPhase, startedAt: fix.timestamp)
                    }
                    lastEnergyTime = nil
                } else if dt > 0 {
                    let meters = previous.isSpeedValid && fix.isSpeedValid
                        ? (previous.speed / 2 + fix.speed / 2) * dt
                        : haversineMeters(from: previous, to: fix)
                    if meters.isFinite {
                        interval = dt
                        distance = max(0, meters)
                        segment.distanceMeters += distance ?? 0
                    }
                }
            }
            segment.locationCount += 1
            lastFix = fix
        }
        segment.samples.append(TripSample(timestamp: fix.timestamp, gpsValid: valid,
            latitude: finite(fix.latitude), longitude: finite(fix.longitude),
            speedMetersPerSecond: valid && fix.isSpeedValid ? fix.speed : nil,
            locationIntervalSeconds: interval, distanceMeters: distance))
        openSegment = segment
    }

    /// 保留原功率入口；没有电压/电流时不借用旧快照填充。
    public mutating func ingestPowerWatts(_ watts: Double, at date: Date) {
        ingestBms(power: watts, voltage: nil, current: nil, at: date)
    }

    /// 快照缺少/包含无效功率时保存无效事件并断开配对；电压电流只来自此快照。
    public mutating func ingestSnapshot(_ snapshot: BmsSnapshot) {
        ingestBms(power: snapshot.power, voltage: snapshot.totalVoltage,
                  current: snapshot.current, at: snapshot.receivedAt)
    }

    private mutating func ingestBms(power: Double?, voltage: Double?, current: Double?, at date: Date) {
        guard state == .recording, var segment = openSegment,
              date.timeIntervalSinceReferenceDate.isFinite, date >= segment.startedAt,
              lastBmsInputTime.map({ date > $0 }) ?? true else { return }
        openSegment = nil
        lastBmsInputTime = date
        // bmsValid 表示此输入可作为能耗来源；不为缺失功率推导/沿用旧值。
        let valid = (power.map { $0.isFinite } ?? false)
            && (voltage.map { $0.isFinite && $0 > 0 } ?? true)
            && (current.map { $0.isFinite } ?? true)
        var interval: TimeInterval?
        var energy: Double?
        if valid, let watts = power {
            if let previous = lastEnergyTime {
                let dt = date.timeIntervalSince(previous)
                let wh = watts * dt / 3600
                if dt > 0, dt <= maxBmsSampleInterval, wh.isFinite {
                    interval = dt
                    energy = wh
                    segment.energyWh += wh
                    segment.energySampleCount += 1
                }
            }
            lastEnergyTime = date
        } else {
            lastEnergyTime = nil
        }
        segment.samples.append(TripSample(timestamp: date, bmsValid: valid,
            powerWatts: power.flatMap { finite($0) }, voltageVolts: voltage.flatMap { finite($0) },
            currentAmps: current.flatMap { finite($0) }, energyIntervalSeconds: interval, energyWh: energy))
        openSegment = segment
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

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
