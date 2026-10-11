import ANTuRideDomain
import SwiftUI

/// Uses the composition root's shared service; this page never starts BLE polling,
/// owns a second session, or generates synthetic acceleration results.
@MainActor
struct AccelerationView: View {
    @EnvironmentObject private var acceleration: AccelerationService
    @AppStorage("acceleration.rpmCoefficientText") private var coefficientText = "0.0782"
    @AppStorage("acceleration.targetSpeedText") private var targetText = "50"
    @AppStorage("acceleration.forwardSign") private var forwardSign = 1
    @State private var inputError: String?

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

    var body: some View {
        List {
            Section("RPM 单渠道 · 实时数据") {
                accelerationValueRow("控制器", acceleration.controllerState.text)
                accelerationValueRow("可用于计时的完整帧", acceleration.hasFreshSnapshot ? "500 ms 内收到非合批帧" : "无有效帧 / 合批 / 超时")
                accelerationValueRow("原始 RPM", acceleration.currentRPM.map { String($0) } ?? "--")
                accelerationValueRow("换算速度", accelerationNumber(displayedSpeed, unit: "km/h"))
                accelerationValueRow("母线电流", accelerationNumber(acceleration.busCurrentA, unit: "A"))
                accelerationValueRow("相线峰值电流", accelerationNumber(acceleration.phasePeakCurrentA, unit: "A"))
                NavigationLink("前往蓝牙设备设置") { BluetoothDevicesView() }
            }
            Section {
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
            } header: { Text("本次参数") } footer: {
                Text("速度 km/h = rawRPM × 系数 × forwardSign。默认系数 0.0782 只是预设，不代表已实车校准；请核对实际前进方向。目标范围 10–200 km/h，系数须为正有限数。")
            }
            .disabled(acceleration.isActive)

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
                    accelerationValueRow("本次状态", accelerationPhaseText(record.phase))
                    if let result = record.result(for: .rpm) {
                        accelerationValueRow("RPM 阶段", accelerationChannelText(result.state))
                        accelerationValueRow("已确认分段", "\(result.splits.count) / \(record.config.targetsKmh.count)")
                        if let reason = result.reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if !record.isActive {
                        NavigationLink("查看本次详情") { AccelerationDetailView(record: record) }
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

            Section("本机 JSON 历史") {
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
                }
            }
            Section("结果边界") {
                Text("时间取自手机接收完整控制器快照事件时的单调时钟，不是硬件测量时刻。分段计时包含蓝牙和手机调度延迟，是接收时序估计；未接入 GPS / IMU，也没有模拟结果或自动校准。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("加速测试")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: coefficientText) { _ in inputError = nil }
        .onChange(of: targetText) { _ in inputError = nil }
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
