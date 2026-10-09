import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("仪表盘", systemImage: "speedometer") }
            Text("行程将在阶段 2 接入")
                .tabItem { Label("行程", systemImage: "map") }
            Text("BMS 详情将在阶段 1 接入")
                .tabItem { Label("详情", systemImage: "battery.100") }
            Text("设置将在阶段 1 接入")
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
