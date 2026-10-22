import ANTuRideDomain
import Combine
import Foundation
import UIKit

/// 锁屏检测通知。用文档化的常量字符串自建 `NSNotification.Name`，
/// 不依赖 `UIApplication` 的 Swift 成员名（不同 SDK 版本命名不一致，CI 已踩坑）。
/// 对应 ObjC 常量 `UIApplicationProtectedDataDidBecomeUnavailableNotification` /
/// `UIApplicationProtectedDataWillBecomeAvailableNotification`。
extension NSNotification.Name {
    static let protectedDataDidBecomeUnavailable = NSNotification.Name(
        "UIApplicationProtectedDataDidBecomeUnavailableNotification"
    )
    static let protectedDataWillBecomeAvailable = NSNotification.Name(
        "UIApplicationProtectedDataWillBecomeAvailableNotification"
    )
}

/// 行程会话服务（阶段 2）：把 GPS 定位与 BMS 快照接入领域层行程记录器。
///
/// 生命周期语义（对应 D3/D4 与验收红线）：
/// - 前台、切后台、锁屏：**均持续记录**。锁屏不再暂停采样
///   （2026-10-22 决策：旧 `suspend` 是当时无法在锁屏继续取数的妥协）。
/// - 真实缺口（低电量模式暂停定位、BLE 断流、GPS 长间隔）由领域层
///   `TripRecorder` 落为 `gap` 段，不插值、不伪造。
///   `TripSegmentKind.suspended` 保留枚举值以兼容旧档案，新行程不再产生。
/// - BLE 断开 / GPS 长间隔：由领域层 `TripRecorder` 落为缺口段，不伪造数据。
///
/// 持久化策略：进行中每 `livePersistInterval` 秒或每 `livePersistSampleThreshold`
/// 个采样落盘一次，锁屏边界与结束时强制落盘；应用被杀最多丢失最近 30 秒的增量。
/// 进行中行程的身份与起点。
///
/// 实时活动需要它来创建活动。不能从 `state` 反推：`@Published` 在赋值前发送事件，
/// 订阅方在收到 `.recording` 的瞬间回读 `tripID` 会拿到旧值（`nil`）。
public struct ActiveTripContext: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date

    public init(id: UUID, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

@MainActor
public final class TripSessionService: NSObject, ObservableObject {
    @Published public private(set) var state: TripState = .idle
    /// 行程会话身份；`nil` 表示当前没有进行中的行程。实时活动的唯一创建/结束依据。
    @Published public private(set) var activeTripContext: ActiveTripContext?
    @Published public private(set) var liveSegments: [TripSegment] = []
    @Published public private(set) var savedTrips: [Trip] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var historyError: String?
    @Published public private(set) var pendingSaveTrip: Trip?

    /// 进行中行程的定期落盘间隔。锁屏续记后不再有「暂停」这个天然落盘时机，
    /// 必须主动落盘，否则进程被系统回收会丢失整段行程。
    static let livePersistInterval: TimeInterval = 30
    static let livePersistSampleThreshold = 30

    private var recorder = TripRecorder()
    private var currentTripID: UUID?
    private var snapshotSubscription: AnyCancellable?
    private var lockObservers: [NSObjectProtocol] = []
    private var currentPhase: TripSegmentKind = .foreground
    private var lastPersistAt = Date()
    private var samplesSincePersist = 0

    private let locationService: LocationService
    private let telemetry: TelemetrySource
    private let store: TripStore

    public init(locationService: LocationService, telemetry: TelemetrySource, store: TripStore = TripStore()) {
        self.locationService = locationService
        self.telemetry = telemetry
        self.store = store
        super.init()
        reloadHistory()
    }

    /// 兼容既有装配与测试：直接把 BLE 服务当作遥测源。
    public convenience init(
        locationService: LocationService,
        bmsService: BmsBluetoothService,
        store: TripStore = TripStore()
    ) {
        self.init(locationService: locationService, telemetry: bmsService, store: store)
    }

    // MARK: - 行程控制

    /// 开始一段新行程。行程中重复调用无副作用（不重复开始）。
    public func startTrip() {
        guard state == .idle else {
            AppLog.location.info("忽略开始行程请求：当前状态 \(state)")
            return
        }
        guard pendingSaveTrip == nil else {
            lastError = "上一段行程尚未保存，请到行程页重试保存或导出。"
            return
        }
        recorder = TripRecorder()
        let tripID = UUID()
        currentTripID = tripID
        currentPhase = UIApplication.shared.applicationState == .background ? .background : .foreground
        let startDate = Date()
        recorder.start(at: startDate, kind: currentPhase)
        state = .recording
        activeTripContext = ActiveTripContext(id: tripID, startedAt: startDate)
        lastError = nil

        locationService.requestPermissionIfNeeded()
        locationService.onFix = { [weak self] fix in
            guard let self else { return }
            self.recorder.ingestLocation(fix)
            self.publishLive()
        }
        locationService.startUpdating()

        // 锁屏继续采样的前提：BLE 在后台保留连接与周期查询（仅降频）。
        (telemetry as? BackgroundTelemetrySustaining)?.setBackgroundTelemetrySustained(true)

        // BMS 快照：按接收时间喂给记录器做能耗配对（功率为 nil 的快照内部自动忽略）。
        // 远程兜底值带设备侧采集时间，通常已超配对窗口而被跳过，不会污染能耗积分。
        snapshotSubscription = telemetry.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self, let snapshot else { return }
                self.recorder.ingestSnapshot(snapshot)
                self.publishLive()
            }

        observeLockState()
        lastPersistAt = Date()
        samplesSincePersist = 0
        publishLive()
        AppLog.location.notice("行程开始 id=\(currentTripID?.uuidString ?? "-")")
    }

    /// 结束行程并持久化。空闲态调用无副作用。
    public func stopTrip() {
        guard state == .recording || state == .suspended else {
            AppLog.location.info("忽略结束行程请求：当前状态 \(state)")
            return
        }
        let tripID = currentTripID ?? UUID()
        if let trip = recorder.finish(at: Date()) {
            let finished = Trip(id: tripID, startedAt: trip.startedAt, endedAt: trip.endedAt, segments: trip.segments)
            if !persist(finished) { pendingSaveTrip = finished }
        }
        teardownSession()
        reloadHistory()
        AppLog.location.notice("行程结束 id=\(tripID.uuidString)")
    }

    // MARK: - 锁屏检测（D4：锁屏暂停，回前台恢复）

    private func observeLockState() {
        guard let sessionID = currentTripID else { return }
        let center = NotificationCenter.default
        lockObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.currentTripID == sessionID else { return }
                self?.updatePhase(.background)
            }
        })
        lockObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.currentTripID == sessionID else { return }
                self?.updatePhase(.foreground)
                self?.handleDeviceUnlocked()
            }
        })
        lockObservers.append(center.addObserver(forName: .protectedDataDidBecomeUnavailable, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.currentTripID == sessionID else { return }
                self?.handleDeviceLocked()
            }
        })
        lockObservers.append(center.addObserver(forName: .protectedDataWillBecomeAvailable, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.currentTripID == sessionID else { return }
                self?.handleDeviceUnlocked()
            }
        })
    }

    private func updatePhase(_ phase: TripSegmentKind) {
        currentPhase = phase
        recorder.setPhase(phase, at: Date())
        publishLive()
    }

    /// 锁屏不再暂停采样：旧实现的 `suspend` 是当时无法在锁屏继续取数的妥协。
    /// 真实缺口（低电量模式暂停定位、BLE 断流）由 `TripRecorder` 的长间隔规则记为 `gap`，
    /// 不插值、不伪造连续。
    private func handleDeviceLocked() {
        guard state == .recording else { return }
        updatePhase(.background)
        persistLive(force: true) // 锁屏边沿强制落盘一次，缩小被回收时的丢失面
        AppLog.location.notice("设备锁定：行程继续记录（后台段）")
    }

    private func handleDeviceUnlocked() {
        guard state == .recording else { return }
        // 解锁只切回前台相位；行程与采样从未中断。
        updatePhase(UIApplication.shared.applicationState == .background ? .background : .foreground)
        AppLog.location.info("设备解锁：继续记录")
    }

    // MARK: - 持久化

    @discardableResult
    private func persist(_ trip: Trip) -> Bool {
        do {
            try store.save(trip)
            return true
        } catch {
            lastError = "行程保存失败：\(error.localizedDescription)"
            AppLog.location.error("行程保存失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 进行中行程落盘。`force` 用于锁屏边界等关键时刻；其余时刻按间隔/采样数节流，
    /// 避免每秒写整个 JSON——长行程的样本数组会持续增长。
    private func persistLive(force: Bool = false) {
        guard state == .recording || state == .suspended else { return }
        guard let id = currentTripID, let startedAt = recorder.startedAt else { return }
        let now = Date()
        if !force {
            let intervalReached = now.timeIntervalSince(lastPersistAt) >= Self.livePersistInterval
            let sampleReached = samplesSincePersist >= Self.livePersistSampleThreshold
            guard intervalReached || sampleReached else { return }
        }
        let live = Trip(id: id, startedAt: startedAt, endedAt: nil, segments: recorder.liveSegments)
        if persist(live) {
            lastPersistAt = now
            samplesSincePersist = 0
        }
    }

    private func publishLive() {
        liveSegments = recorder.liveSegments
        samplesSincePersist += 1
        persistLive()
    }

    private func teardownSession() {
        (telemetry as? BackgroundTelemetrySustaining)?.setBackgroundTelemetrySustained(false)
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        locationService.onFix = nil
        locationService.stopUpdating()
        lockObservers.forEach(NotificationCenter.default.removeObserver)
        lockObservers.removeAll()
        liveSegments = []
        currentTripID = nil
        activeTripContext = nil
        lastPersistAt = Date()
        samplesSincePersist = 0
        state = .idle
    }

    /// 删除保存记录并刷新列表；禁止删除当前进行中的行程。
    public func deleteTrip(id: UUID) {
        guard id != currentTripID else { return }
        do {
            try store.delete(id: id)
            reloadHistory()
        } catch {
            lastError = "行程删除失败：\(error.localizedDescription)"
            AppLog.location.error("行程删除失败：\(id.uuidString)（\(error.localizedDescription)）")
        }
    }

    public func reloadHistory() {
        do {
            savedTrips = try store.loadAll().filter { $0.id != currentTripID }
            historyError = nil
        } catch {
            historyError = "行程读取失败：\(error.localizedDescription)"
            AppLog.location.error("行程读取失败：\(error.localizedDescription)")
        }
    }

    public func retryPendingSave() {
        guard let trip = pendingSaveTrip, persist(trip) else { return }
        pendingSaveTrip = nil
        lastError = nil
        reloadHistory()
    }

    // MARK: - 实时统计（供仪表盘直读）

    public var liveDistanceMeters: Double { liveSegments.reduce(0) { $0 + $1.distanceMeters } }
    public var liveEnergyWh: Double { liveSegments.reduce(0) { $0 + $1.energyWh } }
}
