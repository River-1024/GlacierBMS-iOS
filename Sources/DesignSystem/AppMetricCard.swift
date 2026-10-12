import SwiftUI

/// A read-only metric; callers own freshness, formatting and any interactive wrapper.
struct AppMetricCard: View {
    private let title: String
    private let value: String
    private let unit: String
    private let detail: String?
    private let color: Color
    private let prominent: Bool
    private let valueScale: Double

    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 28
    @ScaledMetric(relativeTo: .largeTitle) private var prominentValueSize: CGFloat = 34

    init(
        title: String,
        value: String,
        unit: String = "",
        detail: String? = nil,
        color: Color = .primary,
        prominent: Bool = false,
        valueScale: Double = 1
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.detail = detail
        self.color = color
        self.prominent = prominent
        self.valueScale = valueScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    valueText.fixedSize(horizontal: true, vertical: true)
                    if !unit.isEmpty { unitText.fixedSize() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    valueText
                    if !unit.isEmpty { unitText }
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Do not merge/ignore children: a wrapping Button retains its own semantics.
        .accessibilityElement(children: .contain)
    }

    private var valueText: some View {
        let scale = valueScale.isFinite && valueScale > 0 ? valueScale : 1
        return Text(value)
            // Numeric display is the only sized font; ScaledMetric supplies Dynamic Type.
            .font(.system(size: (prominent ? prominentValueSize : valueSize) * CGFloat(scale),
                          weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var unitText: some View {
        Text(unit)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppMetricCard_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            previewCards.previewDisplayName("有效与缺失")
            previewCards.preferredColorScheme(.dark).previewDisplayName("深色")
            previewCards.environment(\.dynamicTypeSize, .accessibility5)
                .previewDisplayName("最大辅助字号")
        }
    }

    private static var previewCards: some View {
        VStack(spacing: 8) {
            AppMetricCard(title: "电池电压", value: "72.6", unit: "V", prominent: true)
            AppMetricCard(title: "电流", value: "--", unit: "A", detail: "数据已过期")
            AppMetricCard(title: "连接状态", value: "--", detail: "读取失败", color: AppTheme.danger)
        }
        .padding(16)
        .background(AppTheme.background)
    }
}
