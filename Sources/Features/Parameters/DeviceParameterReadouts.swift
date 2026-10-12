import ANTuRideDomain
import Foundation

/// 纯展示取数：调用方先筛掉断开/过期快照，不初始化 BLE 或推断缺失遥测。
struct DeviceParameterReadout: Equatable {
    let title: String
    let value: String
    let unit: String
    let detail: String?

    static func read(battery snapshot: BmsSnapshot?, metricID: String) -> Self {
        let descriptor = ParameterCatalog.descriptor(metricID, on: .battery)
        var value = "--"
        var detail: String?
        switch metricID {
        case "bms_voltage": value = number(snapshot?.totalVoltage, decimals: 2)
        case "bms_current": value = number(snapshot?.current)
        case "bms_power": value = number(snapshot?.power, decimals: 0)
        case "bms_soc": value = number(snapshot?.soc, decimals: 0)
        case "bms_remaining": value = number(snapshot?.remainingAh)
        case "bms_capacity": value = number(snapshot?.capacityAh)
        case "bms_soh": value = integer(snapshot?.soh)
        case "bms_cell_count": value = integer(snapshot?.cellVoltagesMillivolts.count)
        case "bms_cell_max": value = integer(snapshot?.maxCellVoltageMillivolts)
        case "bms_cell_min": value = integer(snapshot?.minCellVoltageMillivolts)
        case "bms_diff": value = integer(snapshot?.voltageDiffMillivolts)
        case "bms_temperature": value = integer(snapshot?.temperatures.max())
        case "bms_temperature_min": value = integer(snapshot?.temperatures.min())
        case "bms_mos_temperature": value = integer(snapshot?.mosTemperature)
        case "bms_balancer_temperature": value = integer(snapshot?.balancerTemperature)
        case "bms_status": value = snapshot?.statusText ?? "--"
        case "bms_charge_mos": value = mos(snapshot?.chargeMOSOn)
        case "bms_discharge_mos": value = mos(snapshot?.dischargeMOSOn)
        case "bms_balance_status": value = integer(snapshot?.balanceStatus)
        case "bms_balance_mask":
            value = snapshot?.balanceMask.map { "0x" + String($0, radix: 16).uppercased() } ?? "--"
        case "bms_runtime": value = BmsFormatters.runtime(snapshot?.runtimeSeconds) ?? "--"
        case "bms_status_code": value = integer(snapshot?.statusCode)
        case "bms_frame_length": value = integer(snapshot?.frameLength)
        case "bms_unparsed_bytes": value = integer(snapshot?.unparsedBytes)
        default:
            if descriptor != nil, let index = channelIndex(metricID, prefix: "bms_cell_voltage_"),
               let snapshot, snapshot.cellVoltagesMillivolts.indices.contains(index) {
                let millivolts = snapshot.cellVoltagesMillivolts[index]
                value = String(millivolts)
                var markers: [String] = []
                if millivolts == snapshot.maxCellVoltageMillivolts { markers.append("最高") }
                if millivolts == snapshot.minCellVoltageMillivolts { markers.append("最低") }
                detail = markers.isEmpty ? nil : markers.joined(separator: " / ")
            } else if descriptor != nil, let index = channelIndex(metricID, prefix: "bms_probe_temperature_"),
                      let snapshot, snapshot.temperatures.indices.contains(index) {
                value = String(snapshot.temperatures[index])
            }
        }
        return Self(title: descriptor?.title ?? metricID, value: value,
                    unit: value == "--" ? "" : descriptor?.unit ?? "", detail: detail)
    }

    /// 监测计数来自服务累计状态，独立于当前遥测有效性；不能用计数证明仍在更新。
    static func read(controller telemetry: MotorControllerTelemetry?, metricID: String,
                     notificationCount: Int? = nil, frameCount: Int? = nil,
                     pendingByteCount: Int? = nil) -> Self {
        let descriptor = ParameterCatalog.descriptor(metricID, on: .controller)
        var value = "--"
        var detail: String?
        switch metricID {
        case "controller_voltage": value = number(telemetry?.controllerVoltageV, decimals: 2)
        case "controller_bus_current": value = number(telemetry?.busCurrentA, decimals: 2)
        case "controller_phase_current": value = number(telemetry?.phasePeakCurrentA, decimals: 2)
        case "controller_rpm": value = integer(telemetry?.rpm)
        case "controller_temperature": value = integer(telemetry?.controllerTemperatureC)
        case "controller_motor_temperature": value = integer(telemetry?.motorTemperatureC)
        case "controller_throttle_voltage": value = number(telemetry?.throttleVoltageV, decimals: 2)
        case "controller_linear_brake_voltage": value = number(telemetry?.linearBrakeVoltageV, decimals: 2)
        case "controller_run_state": value = telemetry?.runStateText ?? "--"
        case "controller_gear": value = telemetry.map { String($0.gear, radix: 16).uppercased() } ?? "--"
        case "controller_fault": value = telemetry?.faultSummary ?? "--"
        case "controller_given_iq": value = number(telemetry?.givenIqA, decimals: 2)
        case "controller_feedback_iq": value = number(telemetry?.feedbackIqA, decimals: 2)
        case "controller_given_id": value = number(telemetry?.givenIdA, decimals: 2)
        case "controller_field_weakening": value = number(telemetry?.fieldWeakeningA, decimals: 2)
        case "controller_state_bits": value = integer(telemetry?.controllerStateBits)
        case "controller_current_fault_bits": value = integer(telemetry?.faultBits)
        case "controller_port_bits": value = integer(telemetry?.portStatusBits)
        case "controller_history_fault_bits":
            value = integer(telemetry?.historyFaultBits)
            detail = "设备上报的历史故障位，不代表当前故障"
        case "controller_notify_count":
            value = integer(notificationCount)
            detail = "本次连接累计通知，仅供诊断，不代表遥测有效"
        case "controller_frame_count":
            value = integer(frameCount)
            detail = "本次连接累计整帧，仅供诊断，不代表遥测有效"
        case "controller_pending_bytes":
            value = integer(pendingByteCount)
            detail = "接收缓冲区待拼接字节，不代表有效遥测"
        default: break
        }
        return Self(title: descriptor?.title ?? metricID, value: value,
                    unit: value == "--" ? "" : descriptor?.unit ?? "", detail: detail)
    }

    private static func channelIndex(_ id: String, prefix: String) -> Int? {
        guard id.hasPrefix(prefix), let channel = Int(id.dropFirst(prefix.count)), channel > 0 else { return nil }
        return channel - 1
    }

    private static func integer(_ value: Int?) -> String { value.map { String($0) } ?? "--" }

    private static func number(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }

    private static func mos(_ on: Bool?) -> String {
        guard let on else { return "--" }
        return on ? "开启" : "关闭"
    }
}
