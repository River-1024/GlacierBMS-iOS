import SwiftUI

struct RootView: View {
    enum Tab: Hashable {
        case dashboard
        case devices
        case detail
        case trips
        case range
        case settings
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var controller: ControllerBluetoothService

    @State private var selection: Tab = .dashboard

    var body: some View {
        TabView(selection: $selection) {
            DashboardView(goToDeviceSelection: { selection = .devices })
                .tabItem { Label("仪表盘", systemImage: "speedometer") }
                .tag(Tab.dashboard)
            DeviceView()
                .tabItem { Label("设备", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.devices)
            BmsDetailView()
                .tabItem { Label("详情", systemImage: "battery.100") }
                .tag(Tab.detail)
            TripHistoryView()
                .tabItem { Label("行程", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(Tab.trips)
            NavigationStack { RangeView() }
                .tabItem { Label("续航", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(Tab.range)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onAppear { controller.setPollingEnabled(scenePhase == .active) }
        .onChange(of: scenePhase) { phase in controller.setPollingEnabled(phase == .active) }
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
