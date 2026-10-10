import ANTuRideDomain
import CoreLocation
import Foundation

/// GPS 定位采集服务（阶段 2）。
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

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = Self.distanceFilter
        manager.activityType = .automotiveNavigation
        // 行程记录期间不让系统自动暂停定位；暂停语义由锁屏（protectedData）
        // 与行程状态机显式管理，避免「系统静默暂停」伪装成数据缺口。
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - 控制

    /// 申请「使用期间」定位授权。已授权时无副作用。
    public func requestPermissionIfNeeded() {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return }
        AppLog.location.notice("申请 WhenInUse 定位授权")
        manager.requestWhenInUseAuthorization()
    }

    /// 开始定位更新。启用后台定位更新（依赖 UIBackgroundModes: location）。
    public func startUpdating() {
        guard CLLocationManager.locationServicesEnabled() else {
            lastError = "系统定位服务未开启"
            AppLog.location.error("定位启动被拒绝：系统定位服务未开启")
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        isUpdating = true
        lastError = nil
        AppLog.location.notice("启动定位更新（distanceFilter=\(Self.distanceFilter)m，后台更新=开）")
        manager.startUpdatingLocation()
    }

    /// 停止定位更新并清理后台标记。
    public func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isUpdating = false
        AppLog.location.notice("停止定位更新")
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
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for location in locations {
                // 系统可能批量投递缓存点：过旧的点仍交给领域层，
                // 由间隔规则决定是否记为缺口，这里不擅自丢点。
                let fix = self.convert(location)
                self.lastFix = fix
                AppLog.location.debug(
                    "定位：v=\(String(format: "%.1f", fix.speed))m/s acc=\(String(format: "%.0f", fix.horizontalAccuracy))m (\(fix.latitude, format: .number(precision: 5)), \(fix.longitude, format: .number(precision: 5)))"
                )
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
