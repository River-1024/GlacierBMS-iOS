import ActivityKit
import XCTest
@testable import ANTuRide

/// 实时活动更新节流：纯逻辑断言，不需要真机、Widget 或 ActivityKit 运行时。
final class LiveActivityUpdatePolicyTests: XCTestCase {
    private let policy = LiveActivityUpdatePolicy()

    func testFirstPushAlwaysHappens() {
        XCTAssertTrue(policy.shouldPush(previous: nil, next: makeState(), elapsedSeconds: 0))
    }

    func testStationaryIntervalBlocksEarlyPush() {
        let previous = makeState(speed: 0, soc: 80)
        let next = makeState(speed: 0, soc: 82)
        XCTAssertFalse(
            policy.shouldPush(previous: previous, next: next, elapsedSeconds: 2),
            "静止时最小间隔 5s，2s 内的 SOC 变化不应推送"
        )
    }

    func testMovingIntervalAllowsPushAfterOneSecond() {
        let previous = makeState(speed: 30, soc: 80)
        let next = makeState(speed: 31, soc: 82)
        XCTAssertTrue(policy.shouldPush(previous: previous, next: next, elapsedSeconds: 1))
    }

    func testBelowThresholdDoesNotPush() {
        let previous = makeState(speed: 30, soc: 80, power: 500, distance: 1_000)
        let next = makeState(speed: 30.4, soc: 80.2, power: 510, distance: 1_005)
        XCTAssertFalse(policy.shouldPush(previous: previous, next: next, elapsedSeconds: 1))
    }

    func testFreshnessChangePushesImmediately() {
        let previous = makeState(freshness: .fresh)
        let next = makeState(freshness: .stale)
        XCTAssertTrue(
            policy.shouldPush(previous: previous, next: next, elapsedSeconds: 0.1),
            "数据过期必须立即反映，不受最小间隔限制"
        )
    }

    func testValueAppearingCountsAsChange() {
        let previous = makeState(speed: nil)
        let next = makeState(speed: 22)
        XCTAssertTrue(policy.shouldPush(previous: previous, next: next, elapsedSeconds: 1))
    }

    func testValueDisappearingCountsAsChange() {
        let previous = makeState(soc: 80)
        let next = makeState(soc: nil)
        XCTAssertTrue(policy.shouldPush(previous: previous, next: next, elapsedSeconds: 1))
    }

    func testChargingDirectionChangePushesImmediately() {
        let previous = makeState(isCharging: false)
        let next = makeState(isCharging: true)
        XCTAssertTrue(policy.shouldPush(previous: previous, next: next, elapsedSeconds: 0.1))
    }

    private func makeState(
        speed: Double? = 30,
        soc: Double? = 80,
        power: Double? = 500,
        distance: Double = 1_000,
        freshness: RideActivityAttributes.ContentState.Freshness = .fresh,
        isCharging: Bool = false
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            speedKmh: speed,
            socPercent: soc,
            powerWatts: power,
            distanceMeters: distance,
            freshness: freshness,
            isCharging: isCharging,
            source: .local
        )
    }
}
