import ANTuRideDomain
import Charts
import SwiftUI

/// 图表数据构建：纯函数、可单测。
/// 间隙超过 50 ms 断开连线（不跨缺口画误导性连续曲线）；每条连续区间最多 640 点，
/// 分桶保留首/末/极值。时间轴相对起步时刻 t0，t0 之前为静止/等待样本（真实接收数据，不裁剪）。
enum AccelerationChartSeriesBuilder {
    static let maxGapSeconds: Double = 0.05
    static let maxPointsPerRun = 640

    struct Point: Identifiable, Equatable {
        let x: Double
        let y: Double
        let series: Int
        let metric: String
        var id: String { "\(metric)#\(series)#\(String(format: "%.4f", x))" }
    }

    struct SplitMark: Equatable, Identifiable {
        let x: Double
        let label: String
        let isFinal: Bool
        var id: String { label }
    }

    struct Output: Equatable {
        var speed: [Point] = []
        var busCurrent: [Point] = []
        var phaseCurrent: [Point] = []
        /// 时序不确定的电流样本只画孤立点，不参与连线。
        var ambiguousPoints: [Point] = []
        var splitMarks: [SplitMark] = []
        var xMin: Double = 0
        var xMax: Double = 0
    }

    static func build(record: AccelerationRecord) -> Output {
        let result = record.result(for: .rpm)
        let t0 = result?.startTimestamp ?? record.referenceTimestamp
        var output = Output()

        let speedValues = record.speedSamples.map { ($0.timestamp - t0, $0.speedKmh) }
        (output.speed, output.xMin, output.xMax) = (series(speedValues, metric: "速度"), lowest(speedValues), highest(speedValues))

        let lineCurrents = record.currentSamples.filter { !$0.timingAmbiguous }
        let busValues = lineCurrents.map { ($0.timestamp - t0, $0.busCurrentA) }
        output.busCurrent = series(busValues, metric: "母线电流")
        output.xMin = min(output.xMin, lowest(busValues))
        output.xMax = max(output.xMax, highest(busValues))

        let phaseValues = lineCurrents.map { ($0.timestamp - t0, $0.phasePeakCurrentA) }
        output.phaseCurrent = series(phaseValues, metric: "相线峰值电流")
        output.xMin = min(output.xMin, lowest(phaseValues))
        output.xMax = max(output.xMax, highest(phaseValues))

        output.ambiguousPoints = record.currentSamples.filter { $0.timingAmbiguous }.map { sample in
            Point(x: sample.timestamp - t0, y: sample.busCurrentA, series: -1, metric: "母线电流")
        }
        if let splits = result?.splits {
            output.splitMarks = splits.enumerated().map { index, split in
                SplitMark(x: split.crossedAt - t0,
                          label: "\(Int(split.targetSpeedKmh)) km/h",
                          isFinal: index == splits.count - 1)
            }
        }
        output.xMin = min(output.xMin, 0)
        output.xMax = max(output.xMax, 0, output.xMin + 1)
        return output
    }

    /// 单调整数序列 → 连续区间切分 + 降采样。输入必须按 x 升序。
    private static func series(_ values: [(Double, Double)], metric: String) -> [Point] {
        guard !values.isEmpty else { return [] }
        var points: [Point] = []
        points.reserveCapacity(values.count)
        var runIndex = 0
        var runStart = 0
        for index in values.indices {
            if index > 0, values[index].0 - values[index - 1].0 > maxGapSeconds {
                points.append(contentsOf: downsample(Array(values[runStart..<index]), run: runIndex, metric: metric))
                runIndex += 1
                runStart = index
            }
        }
        points.append(contentsOf: downsample(Array(values[runStart...]), run: runIndex, metric: metric))
        return points
    }

    /// 分桶保留每个桶的首、末与极值点，并按时间顺序输出。
    /// 桶数 = maxPointsPerRun / 4，每桶最多 4 个点，保证总数不超过 maxPointsPerRun。
    private static func downsample(_ run: [(Double, Double)], run: Int, metric: String) -> [Point] {
        guard run.count > maxPointsPerRun else {
            return run.enumerated().map { Point(x: $0.element.0, y: $0.element.1, series: run, metric: metric) }
        }
        var kept: [Point] = []
        kept.reserveCapacity(maxPointsPerRun)
        let bucketCount = max(1, maxPointsPerRun / 4)
        let count = run.count
        for bucket in 0..<bucketCount {
            let start = bucket * count / bucketCount
            let end = min(count, (bucket + 1) * count / bucketCount)
            guard start < end else { continue }
            var candidates = [run[start], run[start], run[end - 1], run[end - 1]]
            var minimum = run[start]
            var maximum = run[start]
            for value in run[start..<end] {
                if value.1 < minimum.1 { minimum = value }
                if value.1 > maximum.1 { maximum = value }
            }
            candidates[1] = minimum
            candidates[2] = maximum
            candidates.sort { $0.0 < $1.0 }
            var previousX: Double?
            for value in candidates where value.0 != previousX {
                kept.append(Point(x: value.0, y: value.1, series: run, metric: metric))
                previousX = value.0
            }
        }
        return kept
    }

    private static func lowest(_ values: [(Double, Double)]) -> Double {
        values.first?.0 ?? 0
    }

    private static func highest(_ values: [(Double, Double)]) -> Double {
        values.last?.0 ?? 0
    }
}

/// 详情页的"速度 / 电流 · 同时间轴"曲线。iOS 16 Swift Charts 无双 Y 轴，
/// 速度与电流用上下两张共享时间域的图表达，单位分别标注。
struct AccelerationRecordChartsSection: View {
    let record: AccelerationRecord
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 220

    private var data: AccelerationChartSeriesBuilder.Output {
        AccelerationChartSeriesBuilder.build(record: record)
    }

    var body: some View {
        Section("速度 / 电流 · 同时间轴") {
            if data.speed.count < 2 && data.busCurrent.count + data.phaseCurrent.count + data.ambiguousPoints.count < 2 {
                Text("样本不足，不绘制曲线。").foregroundStyle(.secondary)
            } else {
                if data.speed.count >= 2 { speedChart }
                if data.busCurrent.count + data.phaseCurrent.count >= 2 || !data.ambiguousPoints.isEmpty {
                    currentChart
                }
                Text("时间为相对起步时刻 t0 的秒数（接收时序估计）；t0 之前是等待/静止样本。断开处为接收间隙超过 50 ms，不跨缺口连线、不补造样本。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(chartSummary)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("acceleration-chart-summary")
            }
        }
    }

    private var xDomain: ClosedRange<Double> {
        data.xMin...max(data.xMax, data.xMin + 1)
    }

    private var speedChart: some View {
        Chart(data.speed) { point in
            LineMark(x: .value("时间", point.x), y: .value("速度", point.y),
                     series: .value("连续区间", point.series))
        } background: {
            marks
        }
        .chartXScale(domain: xDomain)
        .chartYAxisLabel("km/h")
        .chartXAxisLabel("s")
        .frame(minHeight: chartHeight)
        .accessibilityLabel(chartSummary)
    }

    private var currentChart: some View {
        Chart {
            ForEach(data.busCurrent + data.phaseCurrent) { point in
                LineMark(x: .value("时间", point.x), y: .value("电流", point.y),
                         series: .value("连续区间", "\(point.metric)#\(point.series)"))
                    .foregroundStyle(by: .value("类型", point.metric))
                    .lineStyle(point.metric == "相线峰值电流" ? StrokeStyle(lineWidth: 2, dash: [4, 3]) : StrokeStyle(lineWidth: 2))
            }
            ForEach(data.ambiguousPoints) { point in
                PointMark(x: .value("时间", point.x), y: .value("电流", point.y))
                    .foregroundStyle(.secondary)
            }
        } background: {
            marks
        }
        .chartXScale(domain: xDomain)
        .chartYAxisLabel("A")
        .chartXAxisLabel("s")
        .frame(minHeight: chartHeight)
        .accessibilityLabel("电流曲线：" + chartSummary)
    }

    /// t0 与达标时刻的参考线；只给最终目标加文字标注，中间分段不标注避免遮挡。
    @ChartContentBuilder private var marks: some ChartContent {
        RuleMark(x: .value("起步", 0.0))
            .foregroundStyle(.secondary)
            .annotation(position: .top, spacing: 4) { Text("t0").font(.caption2) }
        ForEach(data.splitMarks) { mark in
            RuleMark(x: .value("达标", mark.x))
                .foregroundStyle(AppTheme.accent.opacity(0.6))
                .annotation(position: .top, spacing: 4) {
                    if mark.isFinal { Text(mark.label).font(.caption2) }
                }
        }
    }

    /// VoiceOver 可读的同数据文字摘要；曲线不可访问时这就是等价信息。
    private var chartSummary: String {
        let result = record.result(for: .rpm)
        var parts: [String] = []
        if let fastest = data.speed.max(by: { $0.y < $1.y }) {
            parts.append("最高 \(accelerationNumber(fastest.y, unit: "km/h"))")
        }
        if let last = result?.splits.last, result?.state == .reached {
            parts.append("起步后 \(accelerationNumber(last.cumulativeSeconds, unit: "s")) 达到 \(Int(last.targetSpeedKmh)) km/h")
        } else {
            parts.append("未达目标 \(accelerationNumber(record.config.targetSpeedKmh, unit: "km/h"))")
        }
        if let result {
            parts.append("速度样本 \(record.speedSamples.count) 个，有效接收 \(accelerationNumber(result.effectiveHz, unit: "Hz"))，最大间隙 \(accelerationNumber(result.maxGapMs, unit: "ms"))")
        }
        return parts.isEmpty ? "暂无可摘要数据" : parts.joined(separator: "；")
    }
}
