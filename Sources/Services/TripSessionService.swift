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
/// - 前台、切后台（未锁屏）：持续记录（后台定位更新）。
/// - 锁屏：`protectedDataDidBecomeUnavailable` 触发 `suspend`，
///   暂停区间显式记为 `suspended` 段；解锁恢复记录，不重新开始行程。
///   - 注意：未设锁屏密码的设备不会发出 protectedData 通知，
///     该场景下锁屏与后台不可区分，按「继续记录」处理（已记录限制）。
/// - BLE 断开 / GPS 长间隔：由领域层 `TripRecorder` 落为缺口段，不伪造数据。
///
/// 持久化策略：暂停与结束时把整段行程原子写入 `TripStore`；
/// 应用被杀时最多丢失「上次暂停/结束之后」的增量。
@MainActor
public final class TripSessionService: NSObject, ObservableObject {
    @Published public private(set) var state: TripState = .idle
    @Published public private(set) var liveSegments: [TripSegment] = []
    @Published public private(set) var savedTrips: [Trip] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var historyError: String?
    @Published public private(set) var pendingSaveTrip: Trip?

    private var recorder = TripRecorder()
    private var currentTripID: UUID?
    private var snapshotSubscription: AnyCancellable?
    private var lockObservers: [NSObjectProtocol] = []
    private var currentPhase: TripSegmentKind = .foreground

    private let locationService: LocationService
    private let bmsService: BmsBluetoothService
    private let store: TripStore

    public init(locationService: LocationService, bmsService: BmsBluetoothService, store: TripStore = TripStore()) {
        self.locationService = locationService
        self.bmsService = bmsService
        self.store = store
        super.init()
        reloadHistory()
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
        currentTripID = UUID()
        currentPhase = UIApplication.shared.applicationState == .background ? .background : .foreground
        recorder.start(at: Date(), kind: currentPhase)
        state = .recording
        lastError = nil

        locationService.requestPermissionIfNeeded()
        locationService.onFix = { [weak self] fix in
            guard let self else { return }
            self.recorder.ingestLocation(fix)
            self.publishLive()
        }
        locationService.startUpdating()

        // BMS 快照：按接收时间喂给记录器做能耗配对（功率为 nil 的快照内部自动忽略）。
        snapshotSubscription = bmsService.$latestSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self, let snapshot else { return }
                self.recorder.ingestSnapshot(snapshot)
                self.publishLive()
            }

        observeLockState()
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

    private func handleDeviceLocked() {
        guard state == .recording else { return }
        recorder.suspend(at: Date())
        state = .suspended
        publishLive()
        AppLog.location.notice("设备锁定：行程采样暂停")
        persistLive() // 暂停即落盘，降低被杀丢失面
    }

    private func handleDeviceUnlocked() {
        guard state == .suspended, UIApplication.shared.isProtectedDataAvailable else { return }
        let now = Date()
        recorder.resume(at: now)
        recorder.setPhase(currentPhase, at: now)
        state = .recording
        publishLive()
        AppLog.location.notice("设备解锁：行程采样恢复（原行程继续）")
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

    private func persistLive() {
        guard let id = currentTripID, let startedAt = recorder.startedAt else { return }
        let live = Trip(id: id, startedAt: startedAt, endedAt: nil, segments: recorder.liveSegments)
        persist(live)
    }

    private func publishLive() {
        liveSegments = recorder.liveSegments
    }

    private func teardownSession() {
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        locationService.onFix = nil
        locationService.stopUpdating()
        lockObservers.forEach(NotificationCenter.default.removeObserver)
        lockObservers.removeAll()
        liveSegments = []
        currentTripID = nil
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
