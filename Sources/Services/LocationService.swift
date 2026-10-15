import ANTuRideDomain
import CoreLocation
import Foundation

/// 前台仪表盘与行程共享的 GPS 定位采集服务。
///
/// 职责边界：只负责把 `CLLocation` 转成领域层的 `GpsFix` 并回调，
/// 不做行程语义判断（那是 `TripSessionService` / `TripRecorder` 的事）。
///
/// 权限策略：仅申请「使用期间」授权（`requestWhenInUseAuthorization`），
/// 配合 Info.plist 的 `UIBackgroundModes: [location]`，在已开始定位的
/// 会话中切后台仍可继续更新——这是导航类 App 的标准模式，不需要
/// 「始终」授权（D3 决策：未锁屏后台继续记录）。
@MainActor
public final class LocationService: NSObject, ObservableObject {
    /// 定位更新间隔（米）：骑行场景 5 米/次足够，避免 1Hz 高频耗电。
    public static let distanceFilter: CLLocationDistance = 5

    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var lastFix: GpsFix?
    @Published public private(set) var isUpdating = false
    @Published public private(set) var lastError: String?

    /// 每个可用定位点的回调，由 `TripSessionService` 接线。
    public var onFix: ((GpsFix) -> Void)?

    private let manager: CLLocationManager?
    private var demand = LocationUpdateDemand()

    public override convenience init() {
        self.init(createsLocationManager: true)
    }

    /// UI 测试不创建系统定位管理器，也不触发真实定位权限弹窗。
    init(createsLocationManager: Bool) {
        manager = createsLocationManager ? CLLocationManager() : nil
        super.init()
        manager?.delegate = self
        manager?.desiredAccuracy = kCLLocationAccuracyBest
        manager?.distanceFilter = Self.distanceFilter
        manager?.activityType = .automotiveNavigation
        manager?.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - 控制

    /// 前台实时速度独立持有定位需求；短暂 inactive 不释放，避免权限弹窗中断请求。
    public func setForegroundActive(_ active: Bool) {
        demand.isForeground = active
        reconcileUpdates()
    }

    public func requestPermissionIfNeeded() {
        guard let manager, manager.authorizationStatus == .notDetermined else { return }
        AppLog.location.notice("申请 WhenInUse 定位授权")
        manager.requestWhenInUseAuthorization()
    }

    /// 行程开始：增加后台定位需求，不影响前台消费者。
    public func startUpdating() {
        demand.isRecordingTrip = true
        reconcileUpdates()
    }

    /// 行程结束：仅释放行程需求，首页仍在前台时继续采集。
    public func stopUpdating() {
        demand.isRecordingTrip = false
        reconcileUpdates()
    }

    private func reconcileUpdates() {
        guard let manager else { return }
        authorizationStatus = manager.authorizationStatus
        guard demand.needsUpdates else {
            stopLocationUpdates()
            return
        }
        guard CLLocationManager.locationServicesEnabled() else {
            stopLocationUpdates()
            lastError = "系统定位服务未开启"
            return
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = demand.allowsBackgroundUpdates
            manager.showsBackgroundLocationIndicator = demand.allowsBackgroundUpdates
            lastError = nil
            guard !isUpdating else { return }
            // 恢复后等待新定位，不把上次会话的速度当作当前速度。
            lastFix = nil
            isUpdating = true
            AppLog.location.notice("启动定位更新（后台更新=\(demand.allowsBackgroundUpdates)）")
            manager.startUpdatingLocation()
        case .notDetermined:
            stopLocationUpdates()
            requestPermissionIfNeeded()
        case .denied, .restricted:
            stopLocationUpdates()
            lastError = "定位权限未开启，请在系统设置中允许使用期间定位"
        @unknown default:
            stopLocationUpdates()
            lastError = "定位授权状态不可用"
        }
    }

    private func stopLocationUpdates() {
        if isUpdating { manager?.stopUpdatingLocation() }
        manager?.allowsBackgroundLocationUpdates = false
        manager?.showsBackgroundLocationIndicator = false
        isUpdating = false
        lastFix = nil
    }

    private func convert(_ location: CLLocation) -> GpsFix {
        GpsFix(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: location.speed, // 无效时 CoreLocation 返回负值，领域层按 isSpeedValid 判定
            horizontalAccuracy: location.horizontalAccuracy
        )
    }
}

extension LocationService: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = manager.authorizationStatus
            AppLog.location.info("定位授权状态变更：\(manager.authorizationStatus.rawValue)")
            self.reconcileUpdates()
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.isUpdating else { return }
            for location in locations {
                // 系统可能批量投递缓存点：过旧的点仍交给领域层，
                // 由间隔规则决定是否记为缺口，这里不擅自丢点。
                let fix = self.convert(location)
                self.lastFix = fix
                // 首页实时速度不新增坐标日志；行程沿用原有本机诊断边界。
                if self.demand.isRecordingTrip {
                    AppLog.location.debug(
                        String(format: "定位：v=%.1fm/s acc=%.0fm (%.5f, %.5f)",
                               fix.speed, fix.horizontalAccuracy, fix.latitude, fix.longitude)
                    )
                } else {
                    AppLog.location.debug(
                        String(format: "前台速度：v=%.1fm/s acc=%.0fm", fix.speed, fix.horizontalAccuracy)
                    )
                }
                self.onFix?(fix)
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastError = error.localizedDescription
            AppLog.location.warning("定位失败：\(error.localizedDescription)")
        }
    }
}
