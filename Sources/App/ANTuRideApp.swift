import ANTuRideDomain
import SwiftUI

@MainActor
@main
struct ANTuRideApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var bmsService: BmsBluetoothService
    @StateObject private var locationService: LocationService
    @StateObject private var tripSession: TripSessionService
    @StateObject private var rangeService: RangeService
    @StateObject private var controllerService: ControllerBluetoothService
    @StateObject private var drivingSettings: DrivingSettingsStore
    @StateObject private var accelerationService: AccelerationService

    init() {
        // 日志系统必须最先安装：后续所有启动逻辑都应留下痕迹。
        AppLogBootstrap.install()
        // 服务在同一处构造并共享实例：行程会话直接引用 BMS 与定位服务。
        let driving = DrivingSettingsStore()
        let controller = ControllerBluetoothService(startupAutoConnectEnabled: driving.settings.controllerAutoConnectEnabled)
        _controllerService = StateObject(wrappedValue: controller)
        _accelerationService = StateObject(wrappedValue: AccelerationService(controller: controller))
        _drivingSettings = StateObject(wrappedValue: driving)
        let bms = BmsBluetoothService(startupAutoConnectEnabled: driving.settings.bmsAutoConnectEnabled,
                                      queryIntervalMs: driving.settings.bluetoothRefreshIntervalMs)
        let location = LocationService()
        _bmsService = StateObject(wrappedValue: bms)
        _locationService = StateObject(wrappedValue: location)
        let trip = TripSessionService(locationService: location, bmsService: bms, store: Self.tripStore())
        _tripSession = StateObject(wrappedValue: trip)
        let range = RangeService(bms: bms, location: location)
        // 仅生产组合根应用 15min/10s 默认；独立服务测试保留 5min/即时刷新契约。
        range.applyDrivingSettings(driving.settings)
        _rangeService = StateObject(wrappedValue: range)
    }

    private static func tripStore() -> TripStore {
        #if DEBUG
        // 模拟器 UI 测试显式指定隔离目录，绝不读取/清除用户的真实行程。
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-trips-empty") || arguments.contains("--ui-test-trips-seeded") {
            let store = TripStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("UITest-Trips-\(UUID().uuidString)", isDirectory: true))
            if arguments.contains("--ui-test-trips-seeded") {
                let start = Date(timeIntervalSince1970: 1_700_000_000)
                let segments = TripSegmentKind.allCases.enumerated().map { index, kind in
                    TripSegment(kind: kind, startedAt: start.addingTimeInterval(Double(index) * 60),
                                endedAt: start.addingTimeInterval(Double(index + 1) * 60),
                                distanceMeters: kind == .foreground ? 1250 : 0,
                                energyWh: kind == .foreground ? 12.5 : 0,
                                locationCount: kind == .foreground ? 5 : 0,
                                energySampleCount: kind == .foreground ? 4 : 0,
                                invalidLocationCount: 0)
                }
                do {
                    try store.save(Trip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                        startedAt: start, endedAt: start.addingTimeInterval(240), segments: segments))
                } catch { assertionFailure("UI 测试行程创建失败：\(error)") }
            }
            return store
        }
        #endif
        return TripStore()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(bmsService)
                .environmentObject(locationService)
                .environmentObject(tripSession)
                .environmentObject(rangeService)
                .environmentObject(controllerService)
                .environmentObject(drivingSettings)
                .environmentObject(accelerationService)
                .preferredColorScheme(appModel.colorScheme)
        }
    }
}

final class AppModel: ObservableObject {
    @Published var colorScheme: ColorScheme?

    init() {
        colorScheme = nil
    }
}
