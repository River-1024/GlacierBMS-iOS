import ANTuRideDomain
import Combine
import Foundation

/// Android 有效驾驶窗口语义 + 固定 seed/legacy 能量曲线；不学习、不恢复校准数据。
/// 窗口按外设 UUID 本机保存，不保存 GPS 坐标，不上传。
@MainActor
final class RangeService: ObservableObject {
    @Published private(set) var prediction: RangePrediction?
    @Published private(set) var status: RangePredictionStatus = .disconnected
    @Published private(set) var reasonText = "尚未绑定稳定设备 ID，无法安全接入实时续航"
    @Published private(set) var effectiveWhPerKm: Double?
    @Published private(set) var averageSpeedKmh: Double?
    /// 同一窗口 BMS 剩余 Ah 的前后差值；净 Ah 不为正时不显示 km/Ah。
    @Published private(set) var referenceKmPerAh: Double?
    @Published private(set) var accumulatedNetAh = 0.0
    @Published private(set) var nominalCapacityAh = 0.0
    @Published private(set) var deviceID: UUID?
    @Published private(set) var accumulatedDistanceMeters = 0.0
    @Published private(set) var accumulatedNetWh = 0.0
    @Published private(set) var accumulatedDischargeWh = 0.0
    @Published private(set) var accumulatedRegenerationWh = 0.0
    @Published private(set) var effectiveDuration: TimeInterval = 0
    @Published private(set) var validIntervalCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastExportURL: URL?

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let exportDirectory: URL
    private var subscriptions = Set<AnyCancellable>()
    private var connected = false
    private var locationUpdating = false
    private var notBefore: Date
    private var lastClockAt: Date
    private var latestSnapshot: BmsSnapshot?
    private var capacityBaseline: BmsSnapshot?
    private var latestFix: GpsFix?
    private var previousEndpoint: Endpoint?
    private var stationaryCharging = false
    private var window = RangeDrivingWindow()
    private var cachedWindow: RangeDrivingWindow?
    private var voltageSamples: [Date: Double] = [:]
    private static let telemetryMaxAge: TimeInterval = 30
    private static let intervalMaxGap: TimeInterval = 10
    private var bmsPairMaxAge: TimeInterval = 3
    private static let persistenceVersion = "android-driving-window-v1-seed-only"
    // 保留无硬件测试入口的既有默认值；生产 App 会应用 DrivingSettings (15min/10s)。
    @Published private(set) var windowAge: TimeInterval = 300
    @Published private(set) var predictionRefreshInterval: TimeInterval = 0
    private var lastPredictionAt: Date?
    private var lastPersistedAt: Date?
    private var evidenceDirty = false

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         exportDirectory: URL = FileManager.default.temporaryDirectory) {
        self.defaults = defaults
        self.clock = clock
        self.exportDirectory = exportDirectory
        let now = clock()
        notBefore = now
        lastClockAt = now
    }

    convenience init(bms: BmsBluetoothService, location: LocationService, defaults: UserDefaults = .standard) {
        self.init(defaults: defaults)
        observe(bms: bms, location: location)
    }

    /// 与 Android 相同：节流窗口快照，当前剩余 Ah 和安全状态不被刷新周期冻结。
    func applyDrivingSettings(_ settings: DrivingSettings) {
        let safe = settings.normalized()
        let duration = TimeInterval(safe.rangeWindowMinutes * 60)
        let cadence = TimeInterval(safe.rangeRefreshSeconds)
        let pairAge = min(10, max(3, Double(safe.bluetoothRefreshIntervalMs) * 2 / 1_000))
        guard windowAge != duration || predictionRefreshInterval != cadence || bmsPairMaxAge != pairAge else { return }
        if bmsPairMaxAge != pairAge { previousEndpoint = nil }
        bmsPairMaxAge = pairAge
        windowAge = duration
        predictionRefreshInterval = cadence
        window.trim(to: duration)
        evidenceDirty = true
        cachedWindow = nil
        lastPredictionAt = nil
        persistWindow()
        refresh()
    }

    private func observe(bms: BmsBluetoothService, location: LocationService?) {
        connected = bms.state == .ready
        setDeviceID(connected ? bms.connectedDeviceID : nil)
        locationUpdating = location?.isUpdating == true
        // Published 在赋值前发送：直接消费事件参数，不回读旧属性。
        bms.$latestSnapshot.dropFirst().sink { [weak self] snapshot in
            guard let self else { return }
            if let snapshot { self.ingest(snapshot: snapshot) }
            else {
                self.latestSnapshot = nil
                self.previousEndpoint = nil
                self.refresh()
            }
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
                else {
                    self.latestFix = nil
                    self.previousEndpoint = nil
                    self.refresh()
                }
            }.store(in: &subscriptions)
            location.$isUpdating.dropFirst().sink { [weak self] updating in
                self?.setLocationUpdating(updating)
            }.store(in: &subscriptions)
        }
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    func setDeviceID(_ id: UUID?) {
        guard deviceID != id else { return }
        persistWindow()
        deviceID = id
        nominalCapacityAh = id.map { defaults.double(forKey: capacityKey($0)) } ?? 0
        if !nominalCapacityAh.isFinite || nominalCapacityAh < 0 { nominalCapacityAh = 0 }
        window.clear()
        restartSampling(now: clock())
        lastPersistedAt = nil
        evidenceDirty = false
        if let id { restoreWindow(for: id) }
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
        cachedWindow = nil
        lastPredictionAt = nil
        defaults.set(value, forKey: capacityKey(deviceID))
        lastError = nil
        refresh()
        return true
    }

    /// 只忘记驾驶证据，保留容量/配置/行程/其他设备和已导出文件。
    func clearWindow() {
        window.clear()
        evidenceDirty = true
        persistWindow()
        restartSampling(now: clock())
        lastExportURL = nil
        lastError = nil
        refresh()
    }

    func reset() {
        if let deviceID { defaults.removeObject(forKey: capacityKey(deviceID)) }
        nominalCapacityAh = 0
        clearWindow()
    }

    func setConnectionReady(_ ready: Bool) {
        guard connected != ready else { return }
        connected = ready
        if !ready { setDeviceID(nil) }
        restartSampling(now: clock())
        refresh()
    }

    func setLocationUpdating(_ updating: Bool) {
        guard locationUpdating != updating else { return }
        locationUpdating = updating
        persistWindow()
        restartSampling(now: clock())
        refresh()
    }

    /// BMS 更新只更新当前输入，不新增距离或能耗。GPS 回调才推进驾驶 FIFO。
    func ingest(snapshot: BmsSnapshot) {
        let now = clock()
        checkClock(now)
        guard deviceID != nil, connected, snapshot.receivedAt >= notBefore else { return }
        guard snapshot.receivedAt <= now else {
            previousEndpoint = nil
            stop(.noValidIntervals, "拒绝未来时间的 BMS 样本")
            return
        }
        if let latestSnapshot, snapshot.receivedAt == latestSnapshot.receivedAt { return }
        if let latestSnapshot, snapshot.receivedAt < latestSnapshot.receivedAt {
            // New BMS time epoch: discard persisted driving evidence and both endpoint baselines.
            discardDrivingEvidence()
            self.latestSnapshot = nil
            capacityBaseline = nil
            latestFix = nil
            previousEndpoint = nil
            voltageSamples.removeAll()
        }
        latestSnapshot = snapshot
        guard isUsable(snapshot, now: now) else {
            previousEndpoint = nil
            refresh(now: now)
            return
        }
        if let previous = capacityBaseline, hasCapacityJump(from: previous, to: snapshot) {
            discardDrivingEvidence()
            previousEndpoint = nil
        }
        capacityBaseline = snapshot
        voltageSamples[snapshot.receivedAt] = snapshot.totalVoltage
        // Android BMS refresh 会解除旧的停车充电标记，但不会新增驾驶证据。
        if snapshot.current >= 0 { stationaryCharging = false }
        refresh(now: now)
    }

    /// 与 Android 输入采样一致：GPS 端点使用当时最近一次 BMS，最多旧 3–10s；
    /// 不借未来 BMS 回填，不把缺口补成零，不以 GPS 瞬时速度判定驾驶证据。
    func ingest(fix: GpsFix) {
        let now = clock()
        checkClock(now)
        guard deviceID != nil, connected, locationUpdating, fix.timestamp >= notBefore else { return }
        guard fix.timestamp <= now else {
            previousEndpoint = nil
            stop(.noValidIntervals, "拒绝未来时间的 GPS 样本")
            return
        }
        if let latestFix, fix.timestamp == latestFix.timestamp { return }
        if let latestFix, fix.timestamp < latestFix.timestamp {
            // A regressed GPS epoch cannot be joined to the prior driving window.
            discardDrivingEvidence()
            previousEndpoint = nil
            self.latestFix = nil
        }
        latestFix = fix
        guard isUsable(fix, now: now), let snapshot = latestSnapshot,
              isUsable(snapshot, now: now),
              isRecent(snapshot.receivedAt, maxAge: bmsPairMaxAge, now: fix.timestamp) else {
            previousEndpoint = nil
            refresh(now: now)
            return
        }
        let endpoint = Endpoint(fix: fix, bms: snapshot)
        defer { previousEndpoint = endpoint }
        guard let previous = previousEndpoint else {
            // A lone negative-current endpoint is not enough to infer stationary charging.
            refresh(now: now)
            return
        }
        let dt = fix.timestamp.timeIntervalSince(previous.fix.timestamp)
        guard dt > 0, dt <= Self.intervalMaxGap else {
            refresh(now: now)
            return
        }
        let distance = haversineMeters(from: previous.fix, to: fix)
        let span = RangeElectricalSpan(startedAt: previous.fix.timestamp, endedAt: fix.timestamp,
                                       startPowerW: previous.bms.totalVoltage * previous.bms.current,
                                       endPowerW: snapshot.totalVoltage * snapshot.current,
                                       startCurrentA: previous.bms.current, endCurrentA: snapshot.current)
        let interval = RangeDrivingInterval(startedAt: previous.fix.timestamp, endedAt: fix.timestamp,
                                            distanceMeters: distance, electricalSpans: [span],
                                            netAh: previous.bms.remainingAh - snapshot.remainingAh)
        if window.append(interval) {
            stationaryCharging = false
            window.trim(to: windowAge)
            evidenceDirty = true
            // 采样通常 1Hz；最多每 10s 编码一次，不在每帧重写整池。
            if lastPersistedAt.map({ now.timeIntervalSince($0) >= 10 }) != false { persistWindow() }
        } else if interval.netWh.isFinite, interval.netAh.isFinite,
                  distance.isFinite, distance >= 0, distance <= 2_000,
                  distance / dt * 3.6 < 3 {
            stationaryCharging = interval.netWh < 0
        }
        refresh(now: now)
    }

    func refresh(now: Date? = nil) {
        let now = now ?? clock()
        checkClock(now)
        updateWindowMetrics()
        if evidenceDirty, lastPersistedAt.map({ now.timeIntervalSince($0) >= 10 }) != false { persistWindow() }
        guard let deviceID, connected else {
            stop(.disconnected, deviceID == nil ? "尚未绑定稳定设备 ID，无法安全接入实时续航" : nil)
            return
        }
        guard locationUpdating else { stop(.noValidIntervals, "定位流未启动，保留驾驶证据但暂停预测"); return }
        guard let snapshot = latestSnapshot else { stop(.accumulating, "等待本设备新的有效 BMS 样本"); return }
        guard isRecent(snapshot.receivedAt, maxAge: Self.telemetryMaxAge, now: now) else {
            stop(.telemetryStale); return
        }
        guard snapshot.statusCode != 5 else {
            stop(.noValidIntervals, "BMS 报告错误/保护状态，暂停续航估计"); return
        }
        guard isUsable(snapshot, now: now) else { stop(.noValidIntervals, "BMS 电气样本无效"); return }
        guard nominalCapacityAh.isFinite, nominalCapacityAh > 0 else { stop(.capacityInvalid); return }
        guard let fix = latestFix else { stop(.accumulating, "等待新鲜 GPS 样本，不沿用连接前的遥测"); return }
        guard isRecent(fix.timestamp, maxAge: Self.telemetryMaxAge, now: now) else {
            stop(.telemetryStale); return
        }
        guard isUsable(fix, now: now) else { stop(.noValidIntervals, "GPS 样本无效，排除坏区间"); return }
        if stationaryCharging { stop(.charging); return }
        guard let remainingEnergy = AndroidEnergyCurve.remainingEnergyWh(
            remainingAh: snapshot.remainingAh, capacityAh: nominalCapacityAh) else {
            stop(.capacityInvalid); return
        }
        voltageSamples = Dictionary(uniqueKeysWithValues: voltageSamples.filter {
            isRecent($0.key, maxAge: 60, now: now)
        })
        let sortedVoltages = voltageSamples.values.sorted()
        let middle = sortedVoltages.count / 2
        let voltageUsed = sortedVoltages.isEmpty ? snapshot.totalVoltage
            : (sortedVoltages.count % 2 == 1 ? sortedVoltages[middle]
                : (sortedVoltages[middle - 1] + sortedVoltages[middle]) / 2)
        guard voltageUsed.isFinite, voltageUsed > 0 else { stop(.telemetryStale); return }
        // 只缓存窗口；剩余 Ah/Wh 使用最新 BMS。保护状态不等待 cadence。
        if cachedWindow == nil || lastPredictionAt.map({ now.timeIntervalSince($0) >= predictionRefreshInterval }) != false {
            cachedWindow = window
            lastPredictionAt = now
        }
        updateWindowMetrics() // 展示系数与预测使用同一刷新批次，累计证据仍实时更新。
        guard let sampled = cachedWindow else { stop(.accumulating); return }
        guard sampled.predictionStatus == .valid else {
            stop(sampled.predictionStatus); return
        }
        guard let last = window.intervals.last,
              isRecent(last.endedAt, maxAge: Self.telemetryMaxAge, now: now) else {
            stop(.telemetryStale); return
        }
        let result = RangePredictor(settings: RangeSettings(nominalCapacityAh: nominalCapacityAh,
                                                           deviceID: deviceID.uuidString))
            .predict(remainingAh: snapshot.remainingAh, netWh: sampled.netWh,
                     distanceMeters: sampled.distanceMeters, remainingEnergyWh: remainingEnergy)
        prediction = result
        status = result.status
        reasonText = result.reasonText
        if result.status != .valid { hideWindowMetrics() }
    }

    private func updateWindowMetrics() {
        let total = window.summary
        accumulatedDistanceMeters = total.distanceMeters
        accumulatedNetWh = total.netWh
        accumulatedNetAh = total.netAh
        accumulatedDischargeWh = total.dischargeWh
        accumulatedRegenerationWh = total.regenerationWh
        effectiveDuration = total.duration
        validIntervalCount = window.intervals.count
        let sampled = (cachedWindow ?? window).summary
        averageSpeedKmh = sampled.duration > 0 ? sampled.distanceMeters / sampled.duration * 3.6 : nil
        referenceKmPerAh = sampled.netAh > 0 ? sampled.distanceMeters / 1_000 / sampled.netAh : nil
        effectiveWhPerKm = sampled.distanceMeters > 0 ? sampled.netWh / (sampled.distanceMeters / 1_000) : nil
    }

    private func hideWindowMetrics() {
        effectiveWhPerKm = nil
        averageSpeedKmh = nil
        referenceKmPerAh = nil
    }

    private func stop(_ value: RangePredictionStatus, _ reason: String? = nil) {
        prediction = nil
        hideWindowMetrics()
        status = value
        reasonText = reason ?? value.reason
    }

    /// 普通缺口只断配对；显式清除、设备切换、Ah 跳变/时钟回退才清驾驶证据。
    private func restartSampling(now: Date) {
        notBefore = now
        latestSnapshot = nil
        capacityBaseline = nil
        latestFix = nil
        previousEndpoint = nil
        stationaryCharging = false
        voltageSamples.removeAll()
        cachedWindow = nil
        lastPredictionAt = nil
        lastClockAt = now
    }

    private func discardDrivingEvidence() {
        window.clear()
        stationaryCharging = false
        evidenceDirty = true
        cachedWindow = nil
        lastPredictionAt = nil
        voltageSamples.removeAll()
        persistWindow()
    }

    private func checkClock(_ now: Date) {
        if now < lastClockAt {
            discardDrivingEvidence()
            restartSampling(now: now)
        }
        lastClockAt = now
    }

    private func hasCapacityJump(from previous: BmsSnapshot, to current: BmsSnapshot) -> Bool {
        let dt = current.receivedAt.timeIntervalSince(previous.receivedAt)
        guard dt > 0, current.capacityAh.isFinite, current.capacityAh > 0 else { return false }
        let delta = abs(current.remainingAh - previous.remainingAh)
        let explained = (abs(previous.current) + abs(current.current)) / 2 * dt / 3_600
        return delta > explained + current.capacityAh * 0.01
    }

    private func capacityKey(_ id: UUID) -> String { "com.zjsf.anturide.range.capacity.\(id.uuidString)" }
    private func evidenceKey(_ id: UUID) -> String { "com.zjsf.anturide.range.driving.\(id.uuidString)" }
    private func isRecent(_ date: Date, maxAge: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= 0 && age <= maxAge
    }
    private func isUsable(_ value: BmsSnapshot, now: Date) -> Bool {
        let power = value.totalVoltage * value.current
        guard isRecent(value.receivedAt, maxAge: Self.telemetryMaxAge, now: now),
              value.isFreshCandidate, value.totalVoltage.isFinite, value.totalVoltage <= 300,
              value.current.isFinite, abs(value.current) <= 2_000,
              value.remainingAh.isFinite, value.remainingAh >= 0,
              power.isFinite, abs(power) <= 500_000, value.statusCode != 5 else { return false }
        if let reported = value.power {
            guard reported.isFinite else { return false }
            if abs(power) > 50, abs(reported) > 50, (power < 0) != (reported < 0) { return false }
        }
        return true
    }
    private func isUsable(_ fix: GpsFix, now: Date) -> Bool {
        isRecent(fix.timestamp, maxAge: Self.telemetryMaxAge, now: now)
            && fix.isUsable(maxAccuracy: .infinity) && fix.speed.isFinite && fix.speed >= 0
    }
    private func haversineMeters(from a: GpsFix, to b: GpsFix) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 6_371_008.8 * 2 * asin(sqrt(min(1, max(0, h))))
    }
    private struct Endpoint { let fix: GpsFix; let bms: BmsSnapshot }

    // 驾驶证据与容量偏好分开；不是电池校准，重连必须收到新的真实 BMS/GPS。
    private struct StoredWindow: Codable {
        let version: String
        let deviceID: UUID
        let intervals: [RangeDrivingInterval]
    }
    private func persistWindow() {
        guard let deviceID else { return }
        let key = evidenceKey(deviceID)
        guard !window.intervals.isEmpty else {
            defaults.removeObject(forKey: key)
            lastPersistedAt = clock()
            evidenceDirty = false
            return
        }
        do {
            let payload = StoredWindow(version: Self.persistenceVersion, deviceID: deviceID, intervals: window.intervals)
            defaults.set(try JSONEncoder().encode(payload), forKey: key)
            lastPersistedAt = clock()
            evidenceDirty = false
        } catch {
            evidenceDirty = true
            lastError = "保存驾驶窗口失败：\(error.localizedDescription)"
        }
    }
    private func restoreWindow(for id: UUID) {
        guard let data = defaults.data(forKey: evidenceKey(id)), data.count <= 16_000_000,
              let stored = try? JSONDecoder().decode(StoredWindow.self, from: data),
              stored.version == Self.persistenceVersion, stored.deviceID == id,
              stored.intervals.count <= 36_000 else { return }
        let now = clock()
        for interval in stored.intervals where interval.endedAt <= now {
            _ = window.append(interval) // 领域入口重新校验数值、覆盖、重复、重叠和驾驶阈值。
        }
        window.trim(to: windowAge)
    }

    // MARK: - 本地导出（无原始 GPS 坐标，净能耗可包含移动再生）
    private struct ExportInterval: Encodable {
        let startedAt: Date
        let endedAt: Date
        let distanceMeters: Double
        let netWh: Double
        let netAh: Double
        let dischargeWh: Double
        let regenerationWh: Double
        init(_ interval: RangeDrivingInterval) {
            startedAt = interval.startedAt; endedAt = interval.endedAt
            distanceMeters = interval.distanceMeters; netWh = interval.netWh; netAh = interval.netAh
            dischargeWh = interval.dischargeWh; regenerationWh = interval.regenerationWh
        }
    }
    private struct Export: Encodable {
        let energyDataVersion = AndroidEnergyCurve.version
        let schemaVersion = 3
        let model = "Android effective-driving FIFO; built-in seed/legacy; learning disabled"
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
        let dischargeWh: Double
        let regenerationWh: Double
        let effectiveDuration: TimeInterval
        let averageSpeedKmh: Double?
        let referenceKmPerAh: Double?
        let windowSeconds: TimeInterval
        let predictionRefreshSeconds: TimeInterval
        let intervals: [ExportInterval]
    }

    func exportJSON() throws -> URL {
        refresh()
        let payload = Export(generatedAt: clock(), deviceID: deviceID?.uuidString,
                             nominalCapacityAh: nominalCapacityAh > 0 ? nominalCapacityAh : nil,
                             status: status, reason: reasonText, predictedRangeKm: prediction?.predictedRangeKm,
                             whPerKm: effectiveWhPerKm, distanceMeters: accumulatedDistanceMeters,
                             netWh: accumulatedNetWh, netAh: accumulatedNetAh,
                             dischargeWh: accumulatedDischargeWh, regenerationWh: accumulatedRegenerationWh,
                             effectiveDuration: effectiveDuration,
                             averageSpeedKmh: averageSpeedKmh, referenceKmPerAh: referenceKmPerAh,
                             windowSeconds: windowAge, predictionRefreshSeconds: predictionRefreshInterval,
                             intervals: window.intervals.map(ExportInterval.init))
        return try writeExport(extension: "json") {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(payload)
        }
    }

    func exportCSV() throws -> URL {
        refresh()
        let values: [String] = [
            ISO8601DateFormatter().string(from: clock()), deviceID?.uuidString ?? "",
            nominalCapacityAh > 0 ? String(nominalCapacityAh) : "",
            String(accumulatedDistanceMeters), String(accumulatedNetWh),
            effectiveWhPerKm.map { String($0) } ?? "", prediction?.predictedRangeKm.map { String($0) } ?? "",
            status.rawValue, reasonText, String(accumulatedNetAh),
            averageSpeedKmh.map { String($0) } ?? "", referenceKmPerAh.map { String($0) } ?? "",
            String(windowAge), String(predictionRefreshInterval),
            String(accumulatedDischargeWh), String(accumulatedRegenerationWh), String(effectiveDuration)
        ]
        let fields = values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = "generated_at,device_id,nominal_capacity_ah,distance_meters,net_wh,wh_per_km,predicted_range_km,status,reason,net_ah,average_speed_kmh,reference_km_per_ah,window_seconds,prediction_refresh_seconds,discharge_wh,regeneration_wh,effective_duration_seconds\r\n"
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
        case .charging: return "停车充电"
        case .capacityInvalid: return "容量未设置或无效"
        case .undervoltage: return "欠压保护"
        case .disconnected: return "未连接/未绑定设备"
        case .nonPositiveNetEnergy: return "净能耗不足"
        case .accumulating: return "积累中"
        }
    }
}
