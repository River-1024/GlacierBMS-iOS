import SwiftUI

struct RootView: View {
    enum Tab: Hashable {
        case dashboard
        case devices
        case detail
        case settings
    }

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
            SettingsPlaceholderView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
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

private struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            PlaceholderView(title: "设置", message: "校准、续航参数与本地导出将在阶段 3 接入")
                .navigationTitle("设置")
        }
    }
}
