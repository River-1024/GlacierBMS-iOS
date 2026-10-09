import SwiftUI

struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionStatusCard()
                    SpeedCard()
                    HStack(spacing: 12) {
                        MetricCard(title: "综合续航", value: "--", unit: "km")
                        MetricCard(title: "SOC", value: "--", unit: "%")
                    }
                    HStack(spacing: 12) {
                        MetricCard(title: "剩余 Ah", value: "--", unit: "Ah")
                        MetricCard(title: "功率", value: "--", unit: "kW")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("实时曲线").font(.headline)
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 180)
                            .overlay(Text("阶段 1 接入实时数据"))
                    }
                }
                .padding()
            }
            .navigationTitle("冰川智舱")
        }
    }
}

private struct ConnectionStatusCard: View {
    var body: some View {
        HStack {
            Circle().fill(AppTheme.warning).frame(width: 10, height: 10)
            Text("尚未连接 BMS")
            Spacer()
            Text("阶段 0")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SpeedCard: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("--").font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("km/h").foregroundStyle(AppTheme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(AppTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}
