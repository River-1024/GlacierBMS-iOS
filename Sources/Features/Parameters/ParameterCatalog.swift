import ANTuRideDomain
import Foundation

struct ParameterSectionDefinition: Identifiable {
    let id: String
    let title: String
    var initiallyCollapsed: Bool = false
}

/// 页面目录决定指标的真实来源；用户只能调整顺序/显示，不能改变指标语义。
enum ParameterCatalog {
    static func sections(for page: ParameterPage) -> [ParameterSectionDefinition] {
        switch page {
        case .dashboard:
            return [.init(id: "top", title: "重点参数"), .init(id: "vehicle", title: "车辆 / BMS 参数"),
                    .init(id: "controller", title: "控制器参数")]
        case .battery:
            return [.init(id: "battery.pack", title: "电池包"), .init(id: "battery.cells", title: "单体电压"),
                    .init(id: "battery.temperature", title: "温度"), .init(id: "battery.state", title: "工作状态"),
                    .init(id: "battery.diagnostics", title: "通讯诊断", initiallyCollapsed: true)]
        case .controller:
            return [.init(id: "controller.electric", title: "电气与转速"),
                    .init(id: "controller.temperature", title: "温度"), .init(id: "controller.input", title: "输入监测"),
                    .init(id: "controller.state", title: "运行与故障"),
                    .init(id: "controller.professional", title: "专业参数", initiallyCollapsed: true),
                    .init(id: "controller.diagnostics", title: "状态与诊断", initiallyCollapsed: true)]
        }
    }

    static func metrics(for page: ParameterPage) -> [ParameterMetricDescriptor] {
        switch page {
        case .dashboard:
            return HomeParameterMetricDefinition.all.map { metric in
                let source = ParameterSource(rawValue: metric.source.rawValue)!
                return ParameterMetricDescriptor(id: metric.id, title: metric.title, unit: metric.unit,
                    source: source, sectionID: source == .controller ? "controller" : "vehicle",
                    size: metric.id == "controller_fault" || metric.id == "bms_mos_status" ? .wide : .compact)
            }
        case .battery:
            return batteryMetrics
        case .controller:
            return controllerMetrics
        }
    }

    static func descriptor(_ id: String, on page: ParameterPage) -> ParameterMetricDescriptor? {
        metrics(for: page).first { $0.id == id }
    }

    static func defaultLayout(for page: ParameterPage) -> ParameterLayout {
        if page == .dashboard { return migrating(HomeParameterConfig.androidDefault) }
        let defaults = metrics(for: page).filter { !isChannel($0.id) }.map {
            ParameterPlacement(metricID: $0.id, sectionID: $0.sectionID, size: $0.size)
        }
        return ParameterLayout(page: page, placements: defaults)
    }

    /// 已有 v1/v2 分配（包括动态归还卡）逐项保留，旧偏好不会被删除。
    static func migrating(_ legacy: HomeParameterConfig) -> ParameterLayout {
        let placements = (legacy.forHome.assignments ?? []).compactMap { assignment -> ParameterPlacement? in
            guard let slot = HomeParameterSlotDefinition.definition(for: assignment.slotId),
                  let metric = descriptor(assignment.metricId, on: .dashboard) else { return nil }
            let size: ParameterCardSize = slot.id == "top_speed" ? .hero
                : slot.id == "top_range" ? .wide : metric.size
            return ParameterPlacement(metricID: metric.id, sectionID: slot.region.rawValue, size: size)
        }
        return ParameterLayout(page: .dashboard, placements: placements)
    }

    static func isChannel(_ id: String) -> Bool {
        id.hasPrefix("bms_cell_voltage_") || id.hasPrefix("bms_probe_temperature_")
    }

    /// 与 AntProtocol 已接受的上限一致，不由 UI 猜测/创造设备通道。
    static func reportedChannels(cellCount: Int, probeCount: Int) -> [ParameterMetricDescriptor] {
        let cells = Set((0..<min(64, max(0, cellCount))).map { "bms_cell_voltage_\($0 + 1)" })
        let probes = Set((0..<min(16, max(0, probeCount))).map { "bms_probe_temperature_\($0 + 1)" })
        return batteryMetrics.filter { cells.contains($0.id) || probes.contains($0.id) }
    }

    private static let batteryMetrics: [ParameterMetricDescriptor] = {
        func metric(_ id: String, _ title: String, _ unit: String, _ section: String,
                    _ size: ParameterCardSize = .compact) -> ParameterMetricDescriptor {
            .init(id: id, title: title, unit: unit, source: .bms, sectionID: "battery.\(section)", size: size)
        }
        let base: [ParameterMetricDescriptor] = [
            metric("bms_voltage", "总电压", "V", "pack"), metric("bms_current", "电流", "A", "pack"),
            metric("bms_power", "功率", "W", "pack"), metric("bms_soc", "SOC", "%", "pack"),
            metric("bms_remaining", "剩余容量", "Ah", "pack"), metric("bms_capacity", "总容量", "Ah", "pack"),
            metric("bms_soh", "SOH", "%", "pack"),
            metric("bms_cell_count", "已上报单体数量", "个", "cells"),
            metric("bms_cell_max", "最高单体电压", "mV", "cells"),
            metric("bms_cell_min", "最低单体电压", "mV", "cells"), metric("bms_diff", "压差", "mV", "cells"),
            metric("bms_temperature", "最高探头温度", "℃", "temperature"),
            metric("bms_temperature_min", "最低探头温度", "℃", "temperature"),
            metric("bms_mos_temperature", "MOS 温度", "℃", "temperature"),
            metric("bms_balancer_temperature", "均衡温度", "℃", "temperature"),
            metric("bms_status", "BMS 状态", "", "state", .wide),
            metric("bms_charge_mos", "充电 MOS", "", "state"), metric("bms_discharge_mos", "放电 MOS", "", "state"),
            metric("bms_balance_status", "均衡状态码", "", "state"), metric("bms_balance_mask", "均衡位掩码", "", "state"),
            metric("bms_runtime", "运行时间", "", "state", .wide),
            metric("bms_status_code", "BMS 状态码", "", "diagnostics"),
            metric("bms_frame_length", "有效帧字节数", "B", "diagnostics"),
            metric("bms_unparsed_bytes", "未解析字节数", "B", "diagnostics")
        ]
        let cells = (1...64).map { metric("bms_cell_voltage_\($0)", "单体 \($0)", "mV", "cells") }
        let probes = (1...16).map { metric("bms_probe_temperature_\($0)", "探头 \($0)", "℃", "temperature") }
        return base + cells + probes
    }()

    private static let controllerMetrics: [ParameterMetricDescriptor] = {
        func metric(_ id: String, _ title: String, _ unit: String, _ section: String,
                    _ size: ParameterCardSize = .compact) -> ParameterMetricDescriptor {
            .init(id: id, title: title, unit: unit, source: .controller, sectionID: "controller.\(section)", size: size)
        }
        return [
            metric("controller_voltage", "控制器电压", "V", "electric"),
            metric("controller_bus_current", "母线电流", "A", "electric"),
            metric("controller_phase_current", "相峰值电流", "A", "electric"),
            metric("controller_rpm", "转速", "RPM", "electric"),
            metric("controller_temperature", "控制器温度", "℃", "temperature"),
            metric("controller_motor_temperature", "电机温度", "℃", "temperature"),
            metric("controller_throttle_voltage", "转把电压", "V", "input"),
            metric("controller_linear_brake_voltage", "线性刹车电压", "V", "input"),
            metric("controller_run_state", "运行状态", "", "state", .wide), metric("controller_gear", "档位", "", "state"),
            metric("controller_fault", "当前故障", "", "state", .wide),
            metric("controller_given_iq", "给定 Iq", "A", "professional"),
            metric("controller_feedback_iq", "反馈 Iq", "A", "professional"),
            metric("controller_given_id", "给定 Id", "A", "professional"),
            metric("controller_field_weakening", "弱磁电流", "A", "professional"),
            metric("controller_state_bits", "控制器状态位", "", "diagnostics"),
            metric("controller_current_fault_bits", "当前故障位", "", "diagnostics"),
            metric("controller_port_bits", "端口状态位", "", "diagnostics"),
            metric("controller_history_fault_bits", "历史故障位", "", "diagnostics"),
            metric("controller_notify_count", "通知计数", "", "diagnostics"),
            metric("controller_frame_count", "整帧计数", "", "diagnostics"),
            metric("controller_pending_bytes", "待拼接字节", "B", "diagnostics")
        ]
    }()
}
