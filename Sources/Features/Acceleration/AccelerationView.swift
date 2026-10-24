import ANTuRideDomain
import SwiftUI
import UIKit

/// Uses the composition root's shared service; this page never starts BLE polling,
/// owns a second session, or generates synthetic acceleration results.
@MainActor
struct AccelerationView: View {
    @EnvironmentObject private var acceleration: AccelerationService
    @AppStorage("acceleration.rpmCoefficientText") private var coefficientText = "0.0782"
    @AppStorage("acceleration.targetSpeedText") private var targetText = "50"
    @AppStorage("acceleration.forwardSign") private var forwardSign = 1
    @State private var inputError: String?
    @State private var quickTarget: QuickTarget = .custom
    @State private var selectedRecordIDs: Set<String> = []
    @State private var confirmingBatchDeletion = false
    @State private var lastPhase: AccelerationPhase?

    /// 常用目标与自定义输入并存：手动输入 50/80 会自动选中对应快捷项。
    enum QuickTarget: Int, CaseIterable, Identifiable {
        case kmh50 = 50
        case kmh80 = 80
        case custom = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .kmh50: return "0–50"
            case .kmh80: return "0–80"
            case .custom: return "自定义"
            }
        }
    }

    private var coefficient: Double? { decimal(coefficientText) }
    private var target: Double? { decimal(targetText) }
    private var validInputs: Bool {
        guard let coefficient, let target else { return false }
        return coefficient.isFinite && coefficient > 0 && target.isFinite && (10...200).contains(target)
            && (forwardSign == 1 || forwardSign == -1)
    }
    private var displayedSpeed: Double? {
        if acceleration.isActive { return acceleration.currentSpeedKmh }
        guard let raw = acceleration.currentRPM, let coefficient, validInputs else { return nil }
        let speed = Double(raw) * coefficient * Double(forwardSign)
        return speed.isFinite ? speed : nil
    }
    private var liveResult: AccelerationChannelResult? { acceleration.record?.result(for: .rpm) }

    var body: some View {
        List(selection: $selectedRecordIDs) {
            Section {
                Label("安全提醒：仅在合法封闭场地测试；行驶中不要操作手机。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.warning)
            }
            Section("RPM 单渠道 · 实时数据") {
                if acceleration.isActive { liveHero }
                accelerationValueRow("控制器", acceleration.controllerState.text)
                accelerationValueRow("可用于计时的完整帧", acceleration.hasFreshSnapshot ? "500 ms 内收到非合批帧" : "无有效帧 / 合批 / 超时")
                accelerationValueRow("原始 RPM", acceleration.currentRPM.map { String($0) } ?? "--")
                if !acceleration.isActive {
                    accelerationValueRow("换算速度", accelerationNumber(displayedSpeed, unit: "km/h"))
                    accelerationValueRow("母线电流", accelerationNumber(acceleration.busCurrentA, unit: "A"))
                    accelerationValueRow("相线峰值电流", accelerationNumber(acceleration.phasePeakCurrentA, unit: "A"))
                }
                NavigationLink("前往蓝牙设备设置") { BluetoothDevicesView() }
            }
            Section {
                if acceleration.isActive {
                    LabeledContent("测试配置 · 进行中已锁定") {
                        Text("系数 \(coefficientText) · 目标 \(targetText) km/h · 方向 \(forwardSign == 1 ? "+1" : "−1")")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    Picker("快捷目标", selection: $quickTarget) {
                        ForEach(QuickTarget.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("acceleration-quick-target")
                    HStack {
                        Text("RPM 系数")
                        TextField("0.0782", text: $coefficientText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("acceleration-coefficient")
                    }
                    HStack {
                        Text("目标速度 km/h")
                        TextField("50", text: $targetText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("acceleration-target")
                    }
                    Picker("正向 RPM 符号", selection: $forwardSign) {
                        Text("+1 · 正 RPM 为前进").tag(1)
                        Text("−1 · 负 RPM 为前进").tag(-1)
                    }
                    .accessibilityIdentifier("acceleration-direction")
                }
            } header: { Text("本次参数") } footer: {
                Text("速度 km/h = rawRPM × 系数 × forwardSign。默认系数 0.0782 只是预设，不代表已实车校准；请核对实际前进方向。目标范围 10–200 km/h，系数须为正有限数。")
            }

            Section {
                if acceleration.isActive {
                    Button("结束本次测试", role: .destructive) { acceleration.stop() }
                        .accessibilityIdentifier("acceleration-stop")
                } else {
                    Button("开始 RPM 加速测试") { start() }
                        .disabled(!acceleration.canStart || !validInputs)
                        .accessibilityIdentifier("acceleration-start")
                }
                if !validInputs { Text("请填写有效系数和 10–200 km/h 目标速度。").foregroundStyle(AppTheme.warning) }
                if let inputError { Text(inputError).foregroundStyle(AppTheme.danger) }
                if let error = acceleration.lastError { Text(error).foregroundStyle(AppTheme.warning) }
                if let record = acceleration.record {
                    if record.isActive {
                        accelerationValueRow("本次状态", accelerationPhaseText(record.phase))
                        if let result = liveResult {
                            accelerationValueRow("RPM 阶段", accelerationChannelText(result.state))
                            accelerationValueRow("已确认分段", "\(result.splits.count) / \(record.config.targetsKmh.count)")
                        }
                    } else if let result = record.result(for: .rpm), result.state == .reached,
                              let last = result.splits.last {
                        finishedHero(targetKmh: last.targetSpeedKmh, seconds: last.cumulativeSeconds,
                                     splits: result.splits, distance: last.distanceMeters)
                    } else {
                        accelerationValueRow("本次状态", accelerationPhaseText(record.phase))
                        if let result = record.result(for: .rpm) {
                            accelerationValueRow("RPM 阶段", accelerationChannelText(result.state))
                            accelerationValueRow("已确认分段", "\(result.splits.count) / \(record.config.targetsKmh.count)")
                            if let reason = result.reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if !record.isActive {
                        NavigationLink("查看本次详情") { AccelerationDetailView(record: record) }
                            .accessibilityIdentifier("acceleration-detail")
                    }
                }
            } header: { Text("测试") } footer: {
                Text("先连续静止 2 秒，再起步；测试只能在前台进行。数据间隙超过 500 ms、断连或离开前台均中止，不补造样本。开始前请在封闭安全场地做好准备，行驶时不要操作手机。")
            }

            if acceleration.pendingSaveRecord != nil || acceleration.historyError != nil {
                Section("保存 / 读取状态") {
                    if let error = acceleration.historyError { Text(error).foregroundStyle(AppTheme.danger) }
                    if acceleration.pendingSaveRecord != nil {
                        Text("未保存记录仍保留在内存中；保存成功前禁止开始下一次。退出进程前请重试，避免丢失。")
                            .font(.footnote)
                        Button("重试保存") { acceleration.retryPendingSave() }
                            .accessibilityIdentifier("acceleration-retry-save")
                    } else {
                        Button("重新读取历史") { acceleration.reloadHistory() }
                    }
                }
            }

            Section {
                if acceleration.records.isEmpty { Text("暂无已保存记录").foregroundStyle(.secondary) }
                ForEach(acceleration.records) { record in
                    NavigationLink {
                        AccelerationDetailView(record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                            Text("目标 \(accelerationNumber(record.config.targetSpeedKmh, unit: "km/h")) · \(accelerationPhaseText(record.phase))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(record.id)
                }
                if !selectedRecordIDs.isEmpty {
                    Button(role: .destructive) {
                        confirmingBatchDeletion = true
                    } label: {
                        Label("删除所选（\(selectedRecordIDs.count)）", systemImage: "trash")
                    }
                    .accessibilityIdentifier("acceleration-delete-selected")
                }
            } header: {
                Text("本机 JSON 历史")
            } footer: {
                Text("右上角\"编辑\"进入多选；所选记录连同全部分段与样本一起删除，无法恢复。")
            }
            Section("结果边界") {
                Text("时间取自手机接收完整控制器快照事件时的单调时钟，不是硬件测量时刻。分段计时包含蓝牙和手机调度延迟，是接收时序估计；未接入 GPS / IMU，也没有模拟结果或自动校准。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("加速测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !acceleration.records.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            }
        }
        .confirmationDialog("删除已选 \(selectedRecordIDs.count) 条记录？", isPresented: $confirmingBatchDeletion,
                            titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                let selected = acceleration.records.filter { selectedRecordIDs.contains($0.id) }
                acceleration.delete(selected)
                selectedRecordIDs.removeAll()
            }
            .accessibilityIdentifier("acceleration-delete-selected-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除已选记录及其全部分段与速度/电流样本，无法恢复。")
        }
        .onAppear {
            quickTarget = quickTarget(matching: targetText)
            lastPhase = acceleration.record?.phase
        }
        .onChange(of: targetText) { text in
            quickTarget = quickTarget(matching: text)
            inputError = nil
        }
        .onChange(of: quickTarget) { item in
            // 自定义不清空输入；快捷项把输入框规范为对应值。
            if item == .kmh50 { targetText = "50" }
            if item == .kmh80 { targetText = "80" }
        }
        .onChange(of: coefficientText) { _ in inputError = nil }
        .onChange(of: acceleration.record?.phase) { phase in
            defer { lastPhase = phase }
            guard phase == .completed, lastPhase != .completed else { return }
            fireCompletionFeedback()
        }
    }

    /// 进行中的主读数：大号速度 + 已用时 + 电流实时/峰值；armed 阶段不显示伪零耗时。
    private var liveHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(liveResult.map { accelerationChannelText($0.state) } ?? accelerationPhaseText(.armed))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let elapsed = acceleration.elapsedSeconds {
                    Text("已用时 \(String(format: "%.1f", elapsed)) s")
                        .font(.headline).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(accelerationNumber(acceleration.currentSpeedKmh, unit: ""))
                    .font(.largeTitle.weight(.semibold)).monospacedDigit()
                Text("km/h").foregroundStyle(.secondary)
            }
            accelerationValueRow("母线电流", currentWithPeak(acceleration.busCurrentA, acceleration.peakBusCurrentA))
            accelerationValueRow("相线峰值电流", currentWithPeak(acceleration.phasePeakCurrentA, acceleration.peakPhasePeakCurrentA))
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("acceleration-live-hero")
    }

    /// 结束且达标的总成绩；未达标的阶段与原因由常规行展示。
    private func finishedHero(targetKmh: Double, seconds: Double, splits: [AccelerationSplit], distance: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("总成绩 0–\(accelerationNumber(targetKmh, unit: "km/h"))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.success)
            Text("\(accelerationNumber(seconds, unit: "")) s")
                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                .foregroundStyle(AppTheme.success)
            Text("已确认分段 \(splits.count) · RPM 换算距离 \(accelerationNumber(distance, unit: "m"))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("acceleration-result-hero")
    }

    /// 达标完成反馈：3 次 success 触感（间隔 0.3 s）。替代上游的闪屏+蜂鸣：
    /// 无闪烁动画天然兼容"减少动态效果"；系统音效无稳定公开 API 且受静音键影响，不采用。
    private func fireCompletionFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            generator.notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 300_000_000)
            generator.notificationOccurred(.success)
        }
    }

    private func currentWithPeak(_ current: Double?, _ peak: Double?) -> String {
        var parts = [accelerationNumber(current, unit: "A")]
        if let peak { parts.append("峰值 \(accelerationNumber(peak, unit: "A"))") }
        return parts.joined(separator: " · ")
    }

    private func quickTarget(matching text: String) -> QuickTarget {
        guard let value = decimal(text), value.isFinite else { return .custom }
        if value == Double(QuickTarget.kmh50.rawValue) { return .kmh50 }
        if value == Double(QuickTarget.kmh80.rawValue) { return .kmh80 }
        return .custom
    }

    private func start() {
        guard let coefficient, let target else { inputError = "请输入有效数字。"; return }
        do {
            try acceleration.start(targetSpeedKmh: target, rpmKmhPerUnit: coefficient, rpmForwardSign: forwardSign)
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }

    private func decimal(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}
