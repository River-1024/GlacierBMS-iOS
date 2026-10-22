import ANTuRideDomain
import Combine
import Foundation

/// 本地优先的遥测融合器。
///
/// 策略（产品明确要求）：
/// 1. 本地 BLE 有新鲜快照（年龄 ≤ `localFreshWindow`）时**绝不请求远程**。
/// 2. 本地无快照或已过期，才按需拉取远程一次；两次请求之间有 `remoteCooldown`，
///    避免 BLE 断连期间反复打满网络与电量。
/// 3. 本地恢复新鲜后立即切回本地，并取消进行中的远程请求。
/// 4. 展示值始终取「`receivedAt` 更新的一方」，不允许旧数据覆盖新数据。
///
/// 远程值必须带设备侧采集时间（见 `RemoteTelemetry`），因此它天然会被
/// `BmsFreshnessEvaluator` 判为过期、被 `TripRecorder` 跳过能耗配对——
/// 远程数据只用于展示兜底，不参与积分与统计。
@MainActor
public final class FusedTelemetrySource: ObservableObject, TelemetrySource {
    public let local: TelemetrySource
    private let remote: RemoteTelemetryProviding?
    private let now: () -> Date
    private let localFreshWindow: TimeInterval
    private let remoteCooldown: TimeInterval
    private let probeInterval: TimeInterval

    @Published public private(set) var latestSnapshot: BmsSnapshot?
    @Published public private(set) var linkState: TelemetryLinkState = .unavailable
    @Published public private(set) var telemetryOrigin: TelemetryOrigin = .none
    @Published public private(set) var telemetryAvailability: TelemetryAvailability = .offline
    @Published public private(set) var telemetryDeviceID: UUID?
    /// 诊断用：最近一次远程成功/失败。不参与实时指标与实时活动。
    @Published public private(set) var lastRemoteFetchAt: Date?
    @Published public private(set) var lastRemoteError: String?

    private var remoteDeviceID: UUID?
    private var lastRemoteAttemptAt: Date?
    private var remoteTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// - Parameters:
    ///   - localFreshWindow: 本地快照可视为实时的最长年龄，默认 5 秒（与 `BmsFreshnessEvaluator` 一致）。
    ///   - remoteCooldown: 两次远程请求的最小间隔，默认 10 秒。
    public init(
        local: TelemetrySource,
        remote: RemoteTelemetryProviding? = nil,
        localFreshWindow: TimeInterval = 5,
        remoteCooldown: TimeInterval = 10,
        probeInterval: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) {
        self.local = local
        self.remote = remote
        self.localFreshWindow = localFreshWindow
        self.remoteCooldown = remoteCooldown
        self.probeInterval = probeInterval
        self.now = now
        bind()
    }

    // MARK: - TelemetrySource

    public var snapshotPublisher: AnyPublisher<BmsSnapshot?, Never> {
        $latestSnapshot.eraseToAnyPublisher()
    }

    public var linkStatePublisher: AnyPublisher<TelemetryLinkState, Never> {
        $linkState.eraseToAnyPublisher()
    }

    public var deviceIDPublisher: AnyPublisher<UUID?, Never> {
        $telemetryDeviceID.eraseToAnyPublisher()
    }

    // MARK: - 订阅与探测

    private func bind() {
        local.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleLocalSnapshot(snapshot) }
            .store(in: &cancellables)
        local.linkStatePublisher
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // 本地不再上报时（例如 BLE 静默断流）也需要推进过期判定与远程兜底，
        // 因此保留一个低频探测；该定时器只在主线程运行，不产生高频开销。
        // 但「既无本地快照、又没接远程」时没有任何状态会随时间变化，
        // 此时必须直接跳过：否则每次 tick 都会走一遍派发，
        // 订阅方（SwiftUI 视图树）被反复失效，长按菜单与拖拽手势会被打断。
        Timer.publish(every: probeInterval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.remote != nil || self.local.latestSnapshot != nil else { return }
                self.refresh()
            }
            .store(in: &cancellables)
        refresh()
    }

    /// `@Published` 在赋值前发送，因此这里直接消费事件参数，不回读 `local.latestSnapshot`。
    private func handleLocalSnapshot(_ snapshot: BmsSnapshot?) {
        guard let snapshot else {
            // 本地明确无数据：没有远程兜底时立即清空，避免下游（续航预测、实时活动）
            // 把陈旧值当成可用数据——这与旧 BLE 断开即置 nil 的语义一致。
            if remote == nil {
                cancelRemote()
                setOrigin(.none)
                remoteDeviceID = nil
                if latestSnapshot != nil { latestSnapshot = nil }
            }
            refresh()
            return
        }
        let age = max(0, now().timeIntervalSince(snapshot.receivedAt))
        guard age <= localFreshWindow else {
            refresh()
            return
        }
        cancelRemote()
        setOrigin(.local)
        remoteDeviceID = nil
        if latestSnapshot != snapshot { latestSnapshot = snapshot }
        recomputeAvailability()
    }

    /// 内部可见以便单元测试直接驱动；生产路径由订阅与定时探测触发。
    func refresh() {
        if let snapshot = local.latestSnapshot {
            let age = max(0, now().timeIntervalSince(snapshot.receivedAt))
            if age <= localFreshWindow {
                cancelRemote()
                setOrigin(.local)
                remoteDeviceID = nil
                if latestSnapshot != snapshot { latestSnapshot = snapshot }
                recomputeAvailability()
                return
            }
            // 本地过期但当前展示的是仍可接受的远程值：保留远程，不降级成更旧的数据。
            if telemetryOrigin == .remote, let existing = latestSnapshot {
                let existingAge = max(0, now().timeIntervalSince(existing.receivedAt))
                if existingAge <= RemoteTelemetry.maxAcceptableAge, existing.receivedAt > snapshot.receivedAt {
                    recomputeAvailability()
                    requestRemoteIfNeeded()
                    return
                }
            }
            // 本地值更新：降级为 stale 展示，并允许远程兜底。
            setOrigin(.local)
            remoteDeviceID = nil
            if latestSnapshot != snapshot { latestSnapshot = snapshot }
        }
        recomputeAvailability()
        requestRemoteIfNeeded()
    }

    // MARK: - 远程兜底

    private func requestRemoteIfNeeded() {
        guard let remote else { return }
        if telemetryOrigin == .remote, let existing = latestSnapshot {
            let age = max(0, now().timeIntervalSince(existing.receivedAt))
            if age <= RemoteTelemetry.maxAcceptableAge { return }
        }
        guard remoteTask == nil else { return }
        let current = now()
        if let last = lastRemoteAttemptAt, current.timeIntervalSince(last) < remoteCooldown { return }
        lastRemoteAttemptAt = current
        remoteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await remote.fetchLatest()
                self.finishRemote(result: result, error: nil)
            } catch {
                self.finishRemote(result: nil, error: error.localizedDescription)
            }
        }
    }

    private func finishRemote(result: RemoteTelemetry?, error: String?) {
        remoteTask = nil
        lastRemoteError = error
        // 请求期间本地恢复新鲜：远程结果作废，不覆盖本地实时值。
        if let localSnapshot = local.latestSnapshot,
           max(0, now().timeIntervalSince(localSnapshot.receivedAt)) <= localFreshWindow {
            return
        }
        guard let result, result.isAcceptable else {
            if telemetryOrigin != .local { recomputeAvailability() }
            return
        }
        // 不允许旧值覆盖新值。
        if let existing = latestSnapshot, existing.receivedAt > result.snapshot.receivedAt { return }
        lastRemoteFetchAt = result.fetchedAt
        setOrigin(.remote)
        remoteDeviceID = result.deviceID
        latestSnapshot = result.snapshot
        recomputeAvailability()
    }

    private func cancelRemote() {
        remoteTask?.cancel()
        remoteTask = nil
    }

    // MARK: - 派生状态

    private func recomputeAvailability() {
        if latestSnapshot == nil { setOrigin(.none) }
        let nextDeviceID: UUID?
        switch telemetryOrigin {
        case .local: nextDeviceID = local.telemetryDeviceID
        case .remote: nextDeviceID = remoteDeviceID
        case .none: nextDeviceID = nil
        }
        if telemetryDeviceID != nextDeviceID { telemetryDeviceID = nextDeviceID }
        guard let snapshot = latestSnapshot else {
            setAvailability(.offline)
            updateLinkState()
            return
        }
        let age = max(0, now().timeIntervalSince(snapshot.receivedAt))
        switch telemetryOrigin {
        case .local:
            setAvailability(age <= localFreshWindow ? .localBLE : .localStale(ageSeconds: age))
        case .remote:
            setAvailability(.remote(ageSeconds: age))
        case .none:
            setAvailability(.offline)
        }
        updateLinkState()
    }

    /// 只在取值实际变化时赋值。`@Published` 在 `willSet` 阶段就会广播，
    /// 无条件赋值会让订阅它的整棵视图树每秒失效——探测定时器因此变成
    /// 「界面永远不进入 idle 状态」，UI 测试里的手势与 `exists` 断言随之失效。
    private func setOrigin(_ next: TelemetryOrigin) {
        if telemetryOrigin != next { telemetryOrigin = next }
    }

    private func setAvailability(_ next: TelemetryAvailability) {
        if telemetryAvailability != next { telemetryAvailability = next }
    }

    private func updateLinkState() {
        let next: TelemetryLinkState
        if local.linkState == .ready {
            next = .ready
        } else if case .remote(let age) = telemetryAvailability, age <= RemoteTelemetry.maxAcceptableAge {
            next = .ready
        } else {
            next = local.linkState
        }
        if linkState != next { linkState = next }
    }
}

extension FusedTelemetrySource: BackgroundTelemetrySustaining {
    /// 只转发给本地源：远程是按需拉取，不需要常驻后台能力。
    public func setBackgroundTelemetrySustained(_ sustained: Bool) {
        (local as? BackgroundTelemetrySustaining)?.setBackgroundTelemetrySustained(sustained)
    }
}
