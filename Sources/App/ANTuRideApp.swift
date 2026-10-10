import SwiftUI

@main
struct ANTuRideApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var bmsService: BmsBluetoothService
    @StateObject private var locationService: LocationService
    @StateObject private var tripSession: TripSessionService

    init() {
        // 日志系统必须最先安装：后续所有启动逻辑都应留下痕迹。
        AppLogBootstrap.install()
        // 服务在同一处构造并共享实例：行程会话直接引用 BMS 与定位服务。
        let bms = BmsBluetoothService()
        let location = LocationService()
        _bmsService = StateObject(wrappedValue: bms)
        _locationService = StateObject(wrappedValue: location)
        _tripSession = StateObject(wrappedValue: TripSessionService(locationService: location, bmsService: bms))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(bmsService)
                .environmentObject(locationService)
                .environmentObject(tripSession)
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
