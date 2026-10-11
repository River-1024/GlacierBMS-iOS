import ANTuRideDomain
import Combine
import Foundation

/// 有效行驶窗口 + 安卓固定能量曲线门面；按产品决定不实现学习/校准。
/// 主线程创建 `RangeService(bms:location:)`，并在连接目标确定时调用
/// `setDeviceID(_:)`（外设 UUID，不是名称）。未提供可靠身份/定位流时明确停算。
@MainActor
final class RangeService: ObservableObject {
    @Published private(set) var prediction: RangePrediction?
    @Published private(set) var status: RangePredictionStatus = .disconnected
    @Published private(set) var reasonText = "尚未绑定稳定设备 ID，无法安全接入实时续航"
    @Published private(set) var effectiveWhPerKm: Double?
    /// 同一有效窗口的位移 / 区间时长，不读取 GPS 瞬时速度或总行程。
    @Published private(set) var averageSpeedKmh: Double?
    /// 同一有效窗口的 km / 真实放电电流积分 Ah；零 Ah 时无参考值。
    @Published private(set) var referenceKmPerAh: Double?
    @Published private(set) var accumulatedNetAh = 0.0
    @Published private(set) var nominalCapacityAh = 0.0 // 0 表示尚未设置，不是默认电池容量。
    @Published private(set) var deviceID: UUID?
    @Published private(set) var accumulatedDistanceMeters = 0.0
    @Published private(set) var accumulatedNetWh = 0.0
    @Published private(set) var validIntervalCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastExportURL: URL?

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let exportDirectory: URL
    private var subscriptions = Set<AnyCancellable>()
    private var bmsService: BmsBluetoothService?
    private var locationService: LocationService?
    private var connected = false
    private var locationUpdating = false
    private var notBefore: Date
    private var latestSnapshot: BmsSnapshot?
    private var latestFix: GpsFix?
    private var previousFix: GpsFix?
    private var bmsSamples: [BmsSnapshot] = []
    private var pending: [(GpsFix, GpsFix)] = []
    private var intervals: [Interval] = []
    private static let bmsMaxAge: TimeInterval = 5
    private static let gpsMaxAge: TimeInterval = 10
    @Published private(set) var windowAge: TimeInterval = 300
    @Published private(set) var predictionRefreshInterval: TimeInterval = 0
    private var lastPredictionAt: Date?
    private var maximumIntervals = 256

    /// 无硬件构造入口：测试可使用隔离 UserDefaults/可控时钟，不触发蓝牙或定位权限。
    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         exportDirectory: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        self.clock = clock
        self.exportDirectory = exportDirectory
        notBefore = clock()
    }

    convenience init(bms: BmsBluetoothService, location: LocationService, defaults: UserDefaults = .standard) {
        self.init(defaults: defaults)
        observe(bms: bms, location: location)
    }

    /// 生产 App 显式配置；无硬件 init 的 5min/即时刷新契约保持不变。
    /// 仅节流有效预测重算，安全状态仍在每次样本/1s heartbeat 立即检查。
    func applyDrivingSettings(_ settings: DrivingSettings) {
        let safe = settings.normalized()
        let window = TimeInterval(safe.rangeWindowMinutes * 60)
        let cadence = TimeInterval(safe.rangeRefreshSeconds)
        guard windowAge != window || predictionRefreshInterval != cadence else { return }
        windowAge = window
        predictionRefreshInterval = cadence
        maximumIntervals = max(256, Int(window) + 1)
        lastPredictionAt = nil
        refresh()
    }

    private func observe(bms: BmsBluetoothService, location: LocationService?) {
        bmsService = bms
        locationService = location
        connected = bms.state == .ready
        setDeviceID(connected ? bms.connectedDeviceID : nil)
        locationUpdating = location?.isUpdating == true
        // @Published 在属性写入前发布：直接消费事件参数，不能在 sink 中回读旧值。
        // 丢弃订阅时重放的缓存值，绑定设备/重置后必须重新收到样本。
        bms.$latestSnapshot.dropFirst().sink { [weak self] snapshot in
            guard let self else { return }
            if let snapshot { self.ingest(snapshot: snapshot) }
            else { self.invalidateWindow(); self.latestSnapshot = nil; self.refresh() }
        }.store(in: &subscriptions)
        bms.$state.combineLatest(bms.$connectedDeviceID).sink { [weak self] state, id in
            guard let self else { return }
            self.setConnectionReady(state == .ready)
            self.setDeviceID(state == .ready ? id : nil)
        }.store(in: &subscriptions)
        if let location {
            location.$lastFix.dropFirst().sink { [weak self] fix in
                guard let self else { return }
                if let fix { self.ingest(fix: fix) }
                else { self.invalidateWindow(); self.latestFix = nil; self.refresh() }
            }.store(in: &subscriptions)
            location.$isUpdating.dropFirst().sink { [weak self] updating in
                self?.setLocationUpdating(updating)
            }.store(in: &subscriptions)
        }
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    /// 由拥有真实连接 UUID 的主线程接线层调用。换设备清空窗口、读取该 UUID 的设置。
    /// 蓝牙服务直接提供外设 UUID；服务不会把可重名的 connectedDeviceName 当作身份。
    func setDeviceID(_ id: UUID?) {
        guard deviceID != id else { return }
        deviceID = id
        nominalCapacityAh = id.map { defaults.double(forKey: capacityKey($0)) } ?? 0
        if !nominalCapacityAh.isFinite || nominalCapacityAh < 0 { nominalCapacityAh = 0 }
        restartSampling()
        lastExportURL = nil
        lastError = nil
        refresh()
    }

    @discardableResult
    func updateNominalCapacityAh(_ value: Double) -> Bool {
        guard let deviceID, value.isFinite, value > 0 else {
            lastError = "请先绑定设备，并输入大于零的有限额定容量（Ah）"
            return false
        }
        nominalCapacityAh = value
        lastPredictionAt = nil
        defaults.set(value, forKey: capacityKey(deviceID))
        lastError = nil
        refresh()
        return true
    }

    /// 只清除当前设备的有效窗口，保留额定容量和窗口/刷新设置。
    /// 不删除行程记录或已导出文件；清除后页面不再把旧导出 URL 当作当前结果。
    func clearWindow() {
        restartSampling()
        lastExportURL = nil
        lastError = nil
        refresh()
    }

    /// 只重置当前设备的容量设置与有效窗口，不影响行程记录/其他设备/已导出文件。
    func reset() {
        if let deviceID { defaults.removeObject(forKey: capacityKey(deviceID)) }
        nominalCapacityAh = 0
        clearWindow()
    }

    // 以下主线程事件接口也用于无硬件测试；真实路径由已有服务的 Published 流驱动。
    func setConnectionReady(_ ready: Bool) {
        guard connected != ready else { return }
        connected = ready
        if !ready { deviceID = nil; nominalCapacityAh = 0 }
        restartSampling()
        refresh()
    }

    func setLocationUpdating(_ updating: Bool) {
        guard locationUpdating != updating else { return }
        locationUpdating = updating
        restartSampling()
        refresh()
    }

    func ingest(snapshot: BmsSnapshot) {
        let now = clock()
        guard deviceID != nil, connected, snapshot.receivedAt >= notBefore else { return }
        guard snapshot.receivedAt <= now else {
            latestSnapshot = nil; invalidateWindow(); refresh(); return
        }
        if let latestSnapshot, snapshot.receivedAt <= latestSnapshot.receivedAt { return }
        latestSnapshot = snapshot
        guard isUsable(snapshot, now: now) else {
            invalidateWindow()
            refresh()
            return
        }
        if let previous = bmsSamples.last,
           snapshot.receivedAt.timeIntervalSince(previous.receivedAt) > Self.bmsMaxAge {
            invalidateWindow()
        }
        bmsSamples.append(snapshot)
        bmsSamples.removeAll { now.timeIntervalSince($0.receivedAt) > 20 }
        if bmsSamples.count > 64 { bmsSamples.removeFirst(bmsSamples.count - 64) }
        consumePending(now: now)
        refresh()
    }

    func ingest(fix: GpsFix) {
        let now = clock()
        guard deviceID != nil, connected, locationUpdating, fix.timestamp >= notBefore else { return }
        guard fix.timestamp <= now else {
            latestFix = nil; invalidateWindow(); refresh(); return
        }
        if let latestFix, fix.timestamp <= latestFix.timestamp { return }
        latestFix = fix
        guard isUsable(fix, now: now), fix.speed >= 1 else {
            invalidateWindow()
            refresh()
            return
        }
        if let previousFix {
            let dt = fix.timestamp.timeIntervalSince(previousFix.timestamp)
            if dt <= Self.gpsMaxAge { pending.append((previousFix, fix)) }
            else { invalidateWindow() }
        }
        previousFix = fix
        if pending.count > 8 { pending.removeFirst(pending.count - 8) }
        consumePending(now: now)
        refresh()
    }

    /// 仅对两端均为有效行驶定位，且 BMS 样本完整覆盖相同时间段的区间积分。
    /// 允许正常采样间的梯形积分；>5s 的 BMS 缺口、停车、充电、保护状态不插值。
    private func consumePending(now: Date) {
        while let pair = pending.first {
            let (start, end) = pair
            guard now.timeIntervalSince(end.timestamp) <= Self.gpsMaxAge else {
                pending.removeFirst(); continue
            }
            guard let last = bmsSamples.last, last.receivedAt >= end.timestamp else { break }
            pending.removeFirst()
            guard let firstIndex = bmsSamples.lastIndex(where: { $0.receivedAt <= start.timestamp }),
                  let lastIndex = bmsSamples.firstIndex(where: { $0.receivedAt >= end.timestamp }),
                  firstIndex < lastIndex else { continue }
            let samples = Array(bmsSamples[firstIndex...lastIndex])
            var energy = 0.0
            var netAh = 0.0
            var covered = true
            for (a, b) in zip(samples, samples.dropFirst()) {
                let dt = b.receivedAt.timeIntervalSince(a.receivedAt)
                guard dt > 0, dt <= Self.bmsMaxAge, let p0 = a.power, let p1 = b.power else {
                    covered = false; break
                }
                let lower = max(start.timestamp, a.receivedAt)
                let upper = min(end.timestamp, b.receivedAt)
                guard upper > lower else { continue }
                let wattsAtStart = p0 + (p1 - p0) * lower.timeIntervalSince(a.receivedAt) / dt
                let wattsAtEnd = p0 + (p1 - p0) * upper.timeIntervalSince(a.receivedAt) / dt
                let ampsAtStart = a.current + (b.current - a.current) * lower.timeIntervalSince(a.receivedAt) / dt
                let ampsAtEnd = a.current + (b.current - a.current) * upper.timeIntervalSince(a.receivedAt) / dt
                let hours = upper.timeIntervalSince(lower) / 3_600
                energy += (wattsAtStart + wattsAtEnd) / 2 * hours
                netAh += (ampsAtStart + ampsAtEnd) / 2 * hours
            }
            let distance = haversineMeters(from: start, to: end)
            // 坐标位移须超过两点误差界，并排除 >60m/s 的定位跳变。
            let dt = end.timestamp.timeIntervalSince(start.timestamp)
            guard covered, energy.isFinite, energy > 0, netAh.isFinite, netAh >= 0, distance.isFinite,
                  distance > start.horizontalAccuracy + end.horizontalAccuracy,
                  distance / dt <= 60 else {
                invalidateWindow()
                return
            }
            intervals.append(Interval(startedAt: start.timestamp, endedAt: end.timestamp,
                                      distanceMeters: distance, netWh: energy, netAh: netAh))
        }
    }

    func refresh(now: Date? = nil) {
        let now = now ?? clock()
        intervals.removeAll { now.timeIntervalSince($0.endedAt) > windowAge }
        // 60min 窗口不能被旧 256 条上限截成约 4min；1s 定位允许保留窗口内区间。
        if intervals.count > maximumIntervals { intervals.removeFirst(intervals.count - maximumIntervals) }
        accumulatedDistanceMeters = intervals.reduce(0) { $0 + $1.distanceMeters }
        accumulatedNetWh = intervals.reduce(0) { $0 + $1.netWh }
        accumulatedNetAh = intervals.reduce(0) { $0 + $1.netAh }
        validIntervalCount = intervals.count
        guard let deviceID else { stop(.disconnected, "尚未绑定稳定设备 ID，无法安全接入实时续航"); return }
        guard connected else { stop(.disconnected); return }
        guard locationUpdating else { stop(.noValidIntervals, "定位流未启动或未接入；续航服务不会自动申请权限"); return }
        guard let snapshot = latestSnapshot else { stop(.accumulating, "等待本设备新的有效 BMS 样本"); return }
        guard isRecent(snapshot.receivedAt, maxAge: Self.bmsMaxAge, now: now) else {
            invalidateWindow(); stop(.telemetryStale); return
        }
        if isCharging(snapshot) { stop(.charging); return }
        // 当前协议只解码到通用错误状态，不能伪称已识别具体欠压/电芯化学体系。
        guard snapshot.statusCode != 5 else { stop(.noValidIntervals, "BMS 报告错误/保护状态，暂停续航估计"); return }
        guard isUsable(snapshot, now: now) else { stop(.noValidIntervals, "BMS 功率或容量样本无效"); return }
        guard nominalCapacityAh.isFinite, nominalCapacityAh > 0 else { stop(.capacityInvalid); return }
        guard let fix = latestFix else { stop(.accumulating, "等待有效行驶定位样本"); return }
        guard isRecent(fix.timestamp, maxAge: Self.gpsMaxAge, now: now) else {
            invalidateWindow(); stop(.telemetryStale, "GPS 数据已过期，不能沿用旧窗口"); return
        }
        guard isUsable(fix, now: now), fix.speed >= 1 else {
            stop(.noValidIntervals, "GPS 无效或车辆未行驶，等待新的有效行驶窗口"); return
        }
        guard let remainingEnergy = AndroidEnergyCurve.remainingEnergyWh(
            remainingAh: snapshot.remainingAh, capacityAh: nominalCapacityAh) else {
            stop(.capacityInvalid); return
        }
        // 窗口指标每次更新；刷新频率仅用于下面的续航预测，不延迟安全校验/真实测量值。
        let distanceKm = accumulatedDistanceMeters / 1_000
        let duration = intervals.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
        averageSpeedKmh = duration > 0 ? accumulatedDistanceMeters / duration * 3.6 : nil
        if accumulatedNetAh > 0 {
            let reference = distanceKm / accumulatedNetAh
            referenceKmPerAh = reference.isFinite ? reference : nil
        } else {
            referenceKmPerAh = nil
        }
        effectiveWhPerKm = distanceKm > 0 ? accumulatedNetWh / distanceKm : nil
        let shouldRefresh = lastPredictionAt.map {
            now < $0 || now.timeIntervalSince($0) >= predictionRefreshInterval
        } ?? true
        // 首个有效窗口/状态恢复立即计算；有效预测期间遵守所选刷新频率。
        if status == .valid, prediction != nil, accumulatedNetWh > 0,
           accumulatedDistanceMeters > 0, !shouldRefresh { return }
        lastPredictionAt = now
        let result = RangePredictor(settings: RangeSettings(nominalCapacityAh: nominalCapacityAh,
                                                            deviceID: deviceID.uuidString))
            .predict(remainingAh: snapshot.remainingAh, netWh: accumulatedNetWh,
                     distanceMeters: accumulatedDistanceMeters, remainingEnergyWh: remainingEnergy)
        prediction = result
        status = result.status
        reasonText = result.reasonText
        if result.status != .valid {
            effectiveWhPerKm = nil
            averageSpeedKmh = nil
            referenceKmPerAh = nil
        }
    }

    private func stop(_ value: RangePredictionStatus, _ reason: String? = nil) {
        prediction = nil
        effectiveWhPerKm = nil
        averageSpeedKmh = nil
        referenceKmPerAh = nil
        lastPredictionAt = nil
        status = value
        reasonText = reason ?? value.reason
    }

    private func restartSampling() {
        notBefore = clock()
        latestSnapshot = nil
        latestFix = nil
        invalidateWindow()
    }

    private func invalidateWindow() {
        lastPredictionAt = nil
        previousFix = nil
        bmsSamples.removeAll()
        pending.removeAll()
        intervals.removeAll()
        accumulatedDistanceMeters = 0
        accumulatedNetWh = 0
        accumulatedNetAh = 0
        averageSpeedKmh = nil
        referenceKmPerAh = nil
        validIntervalCount = 0
        effectiveWhPerKm = nil
        prediction = nil
    }

    private func capacityKey(_ id: UUID) -> String { "com.zjsf.anturide.range.capacity.\(id.uuidString)" }
    private func isRecent(_ date: Date, maxAge: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= maxAge
    }
    private func isCharging(_ value: BmsSnapshot) -> Bool {
        value.statusCode == 2 || value.current < 0 || (value.power.map { $0 < 0 } ?? false)
    }
    private func isUsable(_ value: BmsSnapshot, now: Date) -> Bool {
        guard isRecent(value.receivedAt, maxAge: Self.bmsMaxAge, now: now),
              value.isFreshCandidate, value.totalVoltage.isFinite,
              value.current.isFinite, value.remainingAh.isFinite, value.remainingAh >= 0,
              let watts = value.power, watts.isFinite, watts >= 0,
              !isCharging(value), value.statusCode != 5 else { return false }
        return true
    }
    private func isUsable(_ fix: GpsFix, now: Date) -> Bool {
        isRecent(fix.timestamp, maxAge: Self.gpsMaxAge, now: now)
            && fix.isUsable(maxAccuracy: 50) && fix.speed.isFinite && fix.speed >= 0 && fix.speed <= 60
    }
    private func haversineMeters(from a: GpsFix, to b: GpsFix) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }

    // MARK: - 本地导出（主线程按钮可直接使用返回的 URL / ShareLink）
    private struct Interval: Codable {
        let startedAt: Date
        let endedAt: Date
        let distanceMeters: Double
        let netWh: Double
        let netAh: Double
    }
    private struct Export: Encodable {
        let energyDataVersion = AndroidEnergyCurve.version
        let schemaVersion = 2
        let model = "valid-window; Android built-in seed/legacy; learning disabled"
        let generatedAt: Date
        let deviceID: String?
        let nominalCapacityAh: Double?
        let status: RangePredictionStatus
        let reason: String
        let predictedRangeKm: Double?
        let whPerKm: Double?
        let distanceMeters: Double
        let netWh: Double
        let netAh: Double
        let averageSpeedKmh: Double?
        let referenceKmPerAh: Double?
        let windowSeconds: TimeInterval
        let predictionRefreshSeconds: TimeInterval
        let intervals: [Interval]
    }

    func exportJSON() throws -> URL {
        refresh()
        let payload = Export(generatedAt: clock(), deviceID: deviceID?.uuidString,
                             nominalCapacityAh: nominalCapacityAh > 0 ? nominalCapacityAh : nil,
                             status: status, reason: reasonText, predictedRangeKm: prediction?.predictedRangeKm,
                             whPerKm: effectiveWhPerKm, distanceMeters: accumulatedDistanceMeters,
                             netWh: accumulatedNetWh, netAh: accumulatedNetAh,
                             averageSpeedKmh: averageSpeedKmh, referenceKmPerAh: referenceKmPerAh,
                             windowSeconds: windowAge, predictionRefreshSeconds: predictionRefreshInterval,
                             intervals: intervals)
        return try writeExport(extension: "json") {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(payload)
        }
    }

    func exportCSV() throws -> URL {
        refresh()
        let whPerKmText = effectiveWhPerKm.map { String($0) } ?? ""
        let predictedRangeText = prediction?.predictedRangeKm.map { String($0) } ?? ""
        let averageSpeedText = averageSpeedKmh.map { String($0) } ?? ""
        let referenceText = referenceKmPerAh.map { String($0) } ?? ""
        let values: [String] = [
            ISO8601DateFormatter().string(from: clock()), deviceID?.uuidString ?? "",
            nominalCapacityAh > 0 ? String(nominalCapacityAh) : "",
            String(accumulatedDistanceMeters), String(accumulatedNetWh),
            whPerKmText, predictedRangeText,
            status.rawValue, reasonText, String(accumulatedNetAh),
            averageSpeedText, referenceText,
            String(windowAge), String(predictionRefreshInterval)
        ]
        let fields = values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = "generated_at,device_id,nominal_capacity_ah,distance_meters,net_wh,wh_per_km,predicted_range_km,status,reason,net_ah,average_speed_kmh,reference_km_per_ah,window_seconds,prediction_refresh_seconds\r\n"
            + fields.joined(separator: ",") + "\r\n"
        return try writeExport(extension: "csv") { Data(csv.utf8) }
    }

    func exportJSONURL() throws -> URL { try exportJSON() }
    func exportCSVURL() throws -> URL { try exportCSV() }

    private func writeExport(extension suffix: String, data: () throws -> Data) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = exportDirectory
            .appendingPathComponent("Range-\(formatter.string(from: clock()))-\(UUID().uuidString).\(suffix)")
        lastExportURL = nil
        do {
            try data().write(to: url, options: .atomic)
            lastExportURL = url
            lastError = nil
            return url
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
            throw error
        }
    }
}

extension RangePredictionStatus {
    var localizedName: String {
        switch self {
        case .valid: return "基础估计有效"
        case .telemetryStale: return "遥测过期"
        case .noValidIntervals: return "无有效区间"
        case .charging: return "充电/负功率"
        case .capacityInvalid: return "容量未设置或无效"
        case .undervoltage: return "欠压保护"
        case .disconnected: return "未连接/未绑定设备"
        case .nonPositiveNetEnergy: return "净能耗不足"
        case .accumulating: return "积累中"
        }
    }
}
