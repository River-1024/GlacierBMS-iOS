import ANTuRideDomain
import Foundation

/// 只负责行程展示，不改变记录器的统计语义。
enum TripFormatters {
    static func distance(_ meters: Double, locationCount: Int = 1) -> String {
        guard locationCount > 0, meters.isFinite, meters >= 0 else { return "--" }
        return meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    static func energy(_ wh: Double, sampleCount: Int) -> String {
        guard sampleCount > 0, wh.isFinite else { return "-- Wh" }
        return String(format: "%.1f Wh", wh)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%ldh %02ldm %02lds", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%ldm %02lds", total / 60, total % 60)
    }

    static func kind(_ kind: TripSegmentKind) -> String {
        switch kind {
        case .foreground: return "前台记录"
        case .background: return "后台记录"
        case .suspended: return "暂停"
        case .gap: return "数据缺口"
        }
    }

    static func icon(_ kind: TripSegmentKind) -> String {
        switch kind {
        case .foreground: return "iphone"
        case .background: return "moon"
        case .suspended: return "pause.circle"
        case .gap: return "exclamationmark.triangle"
        }
    }
}
