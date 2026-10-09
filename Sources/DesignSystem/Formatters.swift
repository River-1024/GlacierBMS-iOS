import Foundation

/// 仪表盘数值展示格式化。仅负责展示层格式，不承担领域计算。
enum BmsFormatters {
    static func voltage(_ volts: Double) -> String {
        String(format: "%.2f", volts)
    }

    static func current(_ amps: Double) -> String {
        String(format: "%.1f", amps)
    }

    static func kilowatts(_ watts: Double) -> String {
        String(format: "%.2f", watts / 1000.0)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    static func runtime(_ seconds: UInt32?) -> String? {
        guard let seconds else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%uh%02um", hours, minutes)
        }
        return String(format: "%um%02us", minutes, secs)
    }

    static func millivolts(_ millivolts: Int) -> String {
        String(format: "%d mV", millivolts)
    }
}
