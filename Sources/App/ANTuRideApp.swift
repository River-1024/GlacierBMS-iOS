import SwiftUI

@main
struct ANTuRideApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var bmsService = BmsBluetoothService()

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
