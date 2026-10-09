import SwiftUI

@main
struct GlacierBMSApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
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
