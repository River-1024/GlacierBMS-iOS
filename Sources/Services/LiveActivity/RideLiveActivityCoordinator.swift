import ActivityKit
import Combine
import Foundation

/// 骑行实时活动协调器：把行程会话、遥测与定位接成一条活动生命周期。
///
/// 设计要点：
/// - **只观察，不侵入**：从 `TripSessionService` / `TelemetrySource` / `LocationService`
///   的 `@Published` 驱动，业务服务不需要知道实时活动的存在。
/// - **`pushType: .token` 一次锁定**：该字段在 `request` 时决定、事后不能改。
///   本期没有服务端，令牌只记录不上报；将来接远程推送时无需让用户重建活动。
/// - **残留清理**：崩溃或被强杀会在锁屏留下「永远骑行中」的卡片，冷启动必须清掉。
public final class RideLiveActivityCoordinator: ObservableObject {
    /// 与 `DrivingSettings` 的版本化 JSON 分开存储：向 `DrivingSettings` 增加字段
    /// 会让旧存档解码失败并回退默认值，代价远大于一个新 key。
    public static let enabledDefaultsKey = "com.zjsf.anturide.liveActivityEnabled"
    /// 超过该时长未更新，系统会把活动标记为过期（锁屏变灰），而不是继续展示旧值。
    public static let staleWindow: TimeInterval = 30

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    private let tripSession: TripSessionService
    private let telemetry: TelemetrySource
    private let location: LocationService
    private let defaults: UserDefaults
    private let policy: LiveActivityUpdatePolicy
    private let now: () -> Date

    private var activity: Activity<RideActivityAttributes>?
    private var cancellables = Set<AnyCancellable>()
    private var lastPushedAt: Date?
    private var lastPushedState: RideActivityAttributes.ContentState?

    public init(
        tripSession: TripSessionService,
        telemetry: TelemetrySource,
        location: LocationService,
        defaults: UserDefaults = .standard,
        policy: LiveActivityUpdatePolicy = LiveActivityUpdatePolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.tripSession = tripSession
        self.telemetry = telemetry
        self.location = location
        self.defaults = defaults
        self.policy = policy
        self.now = now
        bind()
        Task { await endOrphanedActivities() }
    }

    /// 系统设置里是否允许实时活动。设置页据此显示降级说明。
    public var systemAllowsActivities: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var isEnabled: Bool {
        defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// UI 回归会点「开始行程」，但不应在模拟器上创建真实活动并留下锁屏卡片。
    private var isUITestEnvironment: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-test-") })
        #else
        return false
        #endif
    }

    // MARK: - 接线

    private func bind() {
        tripSession.$activeTripContext
            .removeDuplicates()
            .sink { [weak self] context in
                guard let self else { return }
                if let context {
                    self.startActivity(with: context)
                } else {
                    self.stopActivity()
                }
            }
            .store(in: &cancellables)

        // 三个输入任一变化都尝试推进；是否真正推送由 `LiveActivityUpdatePolicy` 决定。
        let tick: AnyPublisher<Void, Never> = Publishers.Merge3(
            telemetry.snapshotPublisher.map { _ in () }.eraseToAnyPublisher(),
            location.$lastFix.map { _ in () }.eraseToAnyPublisher(),
            tripSession.$liveSegments.map { _ in () }.eraseToAnyPublisher()
        ).eraseToAnyPublisher()

        tick.sink { [weak self] in self?.pushIfNeeded() }.store(in: &cancellables)
    }

    // MARK: - 生命周期

    private func startActivity(with context: ActiveTripContext) {
        guard !isUITestEnvironment else { return }
        guard activity == nil else { return }
        guard isEnabled else {
            lastError = "已关闭锁屏实时活动"
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "系统设置中已关闭实时活动"
            AppLog.lifecycle.notice("实时活动未创建：系统实时活动开关关闭")
            return
        }
        let attributes = RideActivityAttributes(tripID: context.id, startedAt: context.startedAt)
        let initial = currentState()
        do {
            activity = try requestActivity(attributes: attributes, state: initial)
            lastPushedState = initial
            lastPushedAt = now()
            isRunning = true
            lastError = nil
            observePushToken()
            AppLog.lifecycle.notice("实时活动已创建 trip=\(context.id.uuidString)")
        } catch {
            lastError = "实时活动创建失败：\(error.localizedDescription)"
            AppLog.lifecycle.error("实时活动创建失败：\(error.localizedDescription)")
        }
    }

    private func stopActivity() {
        guard let activity else {
            isRunning = false
            return
        }
        let finalState = currentState()
        self.activity = nil
        lastPushedAt = nil
        lastPushedState = nil
        isRunning = false
        Task { await end(activity, state: finalState) }
        AppLog.lifecycle.notice("实时活动已结束")
    }

    private func pushIfNeeded() {
        guard isEnabled, let activity else { return }
        let current = now()
        let next = currentState()
        let elapsed = lastPushedAt.map { current.timeIntervalSince($0) } ?? .infinity
        guard policy.shouldPush(previous: lastPushedState, next: next, elapsedSeconds: elapsed) else { return }
        lastPushedAt = current
        lastPushedState = next
        Task { await update(activity, state: next) }
    }

    /// App 冷启动清理历史残留。崩溃或强杀会留下「永远骑行中」的卡片。
    private func endOrphanedActivities() async {
        let activities = Activity<RideActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        for activity in activities {
            await end(activity, state: nil)
        }
        AppLog.lifecycle.notice("清理残留实时活动 \(activities.count) 个")
    }

    // MARK: - 当前状态

    private func currentState() -> RideActivityAttributes.ContentState {
        let snapshot = telemetry.latestSnapshot
        let availability = telemetry.telemetryAvailability

        let freshness: RideActivityAttributes.ContentState.Freshness
        switch availability {
        case .localBLE:
            freshness = .fresh
        case .localStale, .remote:
            freshness = .stale
        case .offline:
            freshness = .noData
        }

        let source: RideActivityAttributes.ContentState.Source
        if case .remote = availability { source = .remote } else { source = .local }

        let speed: Double? = {
            guard let fix = location.lastFix, fix.isSpeedValid else { return nil }
            return fix.speed * 3.6
        }()

        return RideActivityAttributes.ContentState(
            speedKmh: speed,
            socPercent: snapshot?.soc,
            powerWatts: snapshot?.power,
            distanceMeters: tripSession.liveDistanceMeters,
            freshness: freshness,
            isCharging: (snapshot?.current ?? 0) < -0.5,
            source: source
        )
    }

    // MARK: - ActivityKit 版本分支

    private func requestActivity(
        attributes: RideActivityAttributes,
        state: RideActivityAttributes.ContentState
    ) throws -> Activity<RideActivityAttributes> {
        if #available(iOS 16.2, *) {
            return try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: now().addingTimeInterval(Self.staleWindow)),
                pushType: .token
            )
        } else {
            return try Activity.request(attributes: attributes, contentState: state, pushType: .token)
        }
    }

    private func update(
        _ activity: Activity<RideActivityAttributes>,
        state: RideActivityAttributes.ContentState
    ) async {
        if #available(iOS 16.2, *) {
            await activity.update(ActivityContent(state: state, staleDate: now().addingTimeInterval(Self.staleWindow)))
        } else {
            await activity.update(using: state)
        }
    }

    private func end(
        _ activity: Activity<RideActivityAttributes>,
        state: RideActivityAttributes.ContentState?
    ) async {
        if #available(iOS 16.2, *) {
            let content = state.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: .immediate)
        } else {
            await activity.end(using: state, dismissalPolicy: .immediate)
        }
    }

    private func observePushToken() {
        guard let activity else { return }
        if #available(iOS 16.2, *) {
            Task { [weak self] in
                for await token in activity.pushTokenUpdates {
                    self?.handlePushToken(token)
                }
            }
        } else if let token = activity.pushToken {
            handlePushToken(token)
        }
    }

    /// 本期没有服务端：只记录，不上报。避免「已拿到令牌」被误认为远程推送已接通。
    private func handlePushToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        AppLog.lifecycle.info("实时活动推送令牌已获取（\(hex.count) 字符），本期未上报服务端")
    }
}
