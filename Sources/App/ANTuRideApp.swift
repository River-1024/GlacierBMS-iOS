import SwiftUI

@main
struct ANTuRideApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var bmsService = BmsBluetoothService()

    init() {
        // 日志系统必须最先安装：后续所有启动逻辑都应留下痕迹。
        AppLogBootstrap.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(bmsService)
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
