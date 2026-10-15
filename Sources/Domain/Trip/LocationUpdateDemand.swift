/// 定位采集需求与行程记录独立：前台需要实时速度，只有行程允许后台采集。
public struct LocationUpdateDemand: Equatable, Sendable {
    public var isForeground = false
    public var isRecordingTrip = false

    public init() {}

    public var needsUpdates: Bool { isForeground || isRecordingTrip }
    public var allowsBackgroundUpdates: Bool { isRecordingTrip }
}
