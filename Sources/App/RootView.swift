import SwiftUI

@MainActor
struct RootView: View {
    enum Tab: Hashable {
        case dashboard
        case battery
        case controller
        case trips
        case settings
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var controller: ControllerBluetoothService
    @EnvironmentObject private var acceleration: AccelerationService
    @EnvironmentObject private var driving: DrivingSettingsStore
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var bms: BmsBluetoothService
    @EnvironmentObject private var range: RangeService

    @State private var selection: Tab = .dashboard
    @State private var hasStartedForeground = false
    @State private var returnedFromBackground = false

    var body: some View {
        // 保持五个固定标签；第六个标签会触发 iPhone 系统 More，不能靠改文案消除。
        TabView(selection: $selection) {
            DashboardView()
                .tabItem { Label("仪表盘", systemImage: "speedometer") }
                .tag(Tab.dashboard)
            BatteryView()
                .tabItem { Label("电池", systemImage: "battery.100") }
                .tag(Tab.battery)
            NavigationStack { ControllerView() }
                .tabItem { Label("控制器", systemImage: "engine.combustion") }
                .tag(Tab.controller)
            TripHistoryView()
                .tabItem { Label("行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(Tab.trips)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear {
            if scenePhase == .active { activateForegroundIfNeeded() }
            else { controller.setPollingEnabled(false) }
        }
        // 使用 Published 事件参数：willSet 阶段反读 driving.settings 会读到旧值。
        .onReceive(driving.$settings) { settings in
            appModel.colorScheme = settings.preferredColorScheme
            bms.applyDrivingSettings(settings)
            range.applyDrivingSettings(settings)
            controller.applyDrivingSettings(settings)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { acceleration.stop(reason: "App 离开前台") }
            if phase == .background {
                returnedFromBackground = true
                bms.pauseForBackground()
            }
            if phase == .active { activateForegroundIfNeeded() }
            else { controller.setPollingEnabled(false) }
        }
    }

    private func activateForegroundIfNeeded() {
        // inactive → active（系统弹窗/控制中心）不生成新的自动重连机会。
        if !hasStartedForeground || returnedFromBackground {
            hasStartedForeground = true
            returnedFromBackground = false
            bms.beginForegroundSession()
            controller.beginForegroundSession()
        }
        controller.setPollingEnabled(true)
    }
}

/// 通用占位视图：用于尚未接入的阶段功能，禁止伪装可用。
struct PlaceholderView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
