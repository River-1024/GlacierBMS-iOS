import ANTuRideDomain
import Foundation

/// Pure presentation rules shared by the dashboard and regression tests.
enum HomeMetricPresentation {
    enum Tone: Equatable { case neutral, green, yellow, red }
    static func temperature(_ snapshot: BmsSnapshot?, settings: DrivingSettings) -> Int? {
        guard let snapshot else { return nil }
        if let index = Int(settings.temperatureSource.trimmingCharacters(in: .whitespaces)),
           index >= 1, index <= snapshot.temperatures.count { return snapshot.temperatures[index - 1] }
        return snapshot.temperatures.max()
    }
    static func tone(_ id: String, snapshot: BmsSnapshot?, speedKmh: Double?, settings: DrivingSettings) -> Tone {
        let s = settings.normalized()
        func rising(_ value: Double?, _ yellow: Double, _ red: Double) -> Tone {
            guard let value, value.isFinite else { return .neutral }
            return value >= red ? .red : value >= yellow ? .yellow : .green
        }
        switch id {
        case "app_gps_speed": return rising(speedKmh, s.powerHeaderSpeedMidKmh, s.powerHeaderSpeedHighKmh)
        case "bms_soc":
            guard let value = snapshot?.soc, value.isFinite else { return .neutral }
            return value <= s.socRedUpperPercent ? .red : value <= s.socYellowUpperPercent ? .yellow : .green
        case "bms_diff": return rising(snapshot?.voltageDiffMillivolts.map(Double.init), s.diffGreenUpperMv, s.diffYellowUpperMv)
        case "bms_temperature": return rising(temperature(snapshot, settings: s).map(Double.init), s.tempGreenUpperC, s.tempYellowUpperC)
        case "bms_power":
            guard let power = snapshot?.power else { return .neutral }
            let ratio = abs(power) / (power >= 0 ? s.dischargeBaseW : s.chargeBaseW)
            return rising(ratio, s.powerYellowStart, s.powerRedStart)
        default: return .neutral
        }
    }
}

extension GpsFix {
    var speedKmhForDisplay: Double? { isSpeedValid ? speed * 3.6 : nil }
}
