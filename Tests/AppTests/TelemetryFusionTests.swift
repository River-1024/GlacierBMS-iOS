import ANTuRideDomain
import Combine
import XCTest
@testable import ANTuRide

/// 遥测融合策略：本地优先、远程兜底、冷却、不覆盖新值。
/// 这些断言只覆盖纯逻辑，不需要真机、Widget 或 BLE 硬件。
@MainActor
final class TelemetryFusionTests: XCTestCase {
    func testLocalFreshNeverRequestsRemote() async {
        let clock = MutableClock()
        let local = StubTelemetrySource()
        local.latestSnapshot = Self.snapshot(at: clock.date)
        let counter = CallCounter()
        let remote = StubRemoteProvider(result: nil, counter: counter)

        let fused = FusedTelemetrySource(local: local, remote: remote, probeInterval: 3_600, now: { clock.date })
        fused.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fused.telemetryOrigin, .local)
        XCTAssertEqual(fused.telemetryAvailability, .localBLE)
        let count = await counter.value()
        XCTAssertEqual(count, 0, "本地新鲜时不得请求远程")
    }

    func testRemoteFillsInWhenLocalMissing() async {
        let clock = MutableClock()
        let local = StubTelemetrySource()
        let captured = clock.date.addingTimeInterval(-15)
        let counter = CallCounter()
        let remote = StubRemoteProvider(
            result: RemoteTelemetry(snapshot: Self.snapshot(at: captured), capturedAt: captured, fetchedAt: clock.date),
            counter: counter
        )

        let fused = FusedTelemetrySource(local: local, remote: remote, probeInterval: 3_600, now: { clock.date })
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(fused.telemetryOrigin, .remote)
        XCTAssertNotNil(fused.latestSnapshot)
        guard case .remote(let age) = fused.telemetryAvailability else {
            XCTFail("本地无数据时应降级为 remote")
            return
        }
        XCTAssertEqual(age, 15, accuracy: 0.5)
        let count = await counter.value()
        XCTAssertEqual(count, 1)
    }

    func testLocalRecoverySwitchesBackWithoutRepeatingRemote() async {
        let clock = MutableClock()
        let local = StubTelemetrySource()
        let captured = clock.date.addingTimeInterval(-15)
        let counter = CallCounter()
        let remote = StubRemoteProvider(
            result: RemoteTelemetry(snapshot: Self.snapshot(at: captured), capturedAt: captured, fetchedAt: clock.date),
            counter: counter
        )
        let fused = FusedTelemetrySource(local: local, remote: remote, probeInterval: 3_600, now: { clock.date })
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fused.telemetryOrigin, .remote)

        local.latestSnapshot = Self.snapshot(at: clock.date)
        fused.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fused.telemetryOrigin, .local)
        XCTAssertEqual(fused.telemetryAvailability, .localBLE)
        let count = await counter.value()
        XCTAssertEqual(count, 1, "本地恢复后不得再请求远程")
    }

    func testStaleLocalIsMarkedNotLive() async {
        let clock = MutableClock()
        let local = StubTelemetrySource()
        local.latestSnapshot = Self.snapshot(at: clock.date.addingTimeInterval(-8))

        let fused = FusedTelemetrySource(local: local, remote: nil, probeInterval: 3_600, now: { clock.date })

        XCTAssertEqual(fused.telemetryOrigin, .local)
        guard case .localStale(let age) = fused.telemetryAvailability else {
            XCTFail("过期本地值必须显式标记为 localStale")
            return
        }
        XCTAssertEqual(age, 8, accuracy: 0.001)
        XCTAssertFalse(fused.telemetryAvailability.isLive)
    }

    func testOlderRemoteValueDoesNotOverwriteNewerLocal() async {
        let clock = MutableClock()
        let local = StubTelemetrySource()
        let localAt = clock.date.addingTimeInterval(-8)
        local.latestSnapshot = Self.snapshot(at: localAt)
        let counter = CallCounter()
        let remoteAt = clock.date.addingTimeInterval(-30)
        let remote = StubRemoteProvider(
            result: RemoteTelemetry(snapshot: Self.snapshot(at: remoteAt), capturedAt: remoteAt, fetchedAt: clock.date),
            counter: counter
        )

        let fused = FusedTelemetrySource(local: local, remote: remote, probeInterval: 3_600, now: { clock.date })
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(fused.latestSnapshot?.receivedAt, localAt, "更旧的远程值不得覆盖较新的本地值")
        XCTAssertEqual(fused.telemetryOrigin, .local)
    }

    func testRemoteCooldownLimitsRepeatedRequests() async {
        let clock = MutableClock()
        let local = StubTelemetrySource()
        let counter = CallCounter()
        let remote = StubRemoteProvider(result: nil, counter: counter)
        let fused = FusedTelemetrySource(
            local: local, remote: remote, remoteCooldown: 10, probeInterval: 3_600, now: { clock.date }
        )
        try? await Task.sleep(nanoseconds: 150_000_000)
        fused.refresh()
        fused.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        var count = await counter.value()
        XCTAssertEqual(count, 1, "冷却期内不得重复请求")

        clock.date = clock.date.addingTimeInterval(11)
        fused.refresh()
        try? await Task.sleep(nanoseconds: 150_000_000)
        count = await counter.value()
        XCTAssertEqual(count, 2, "冷却结束后允许再次请求")
    }

    private static func snapshot(at date: Date, soc: Double = 80, power: Double = 500) -> BmsSnapshot {
        BmsSnapshot(
            receivedAt: date,
            totalVoltage: 72,
            current: 7,
            soc: soc,
            capacityAh: 40,
            remainingAh: 32,
            temperatures: [25],
            mosTemperature: 30,
            balancerTemperature: 28,
            cellVoltagesMillivolts: [3300, 3301],
            power: power,
            statusText: "测试"
        )
    }
}

/// 后台续记只有一处降频开关：行程记录中才允许后台查询，且按 2.5 倍降频。
@MainActor
final class BackgroundTelemetrySustainTests: XCTestCase {
    func testBackgroundMultiplierAppliesOnlyWhileSustained() throws {
        let suiteName = "TelemetryFusionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = BmsBluetoothService(
            defaults: defaults,
            startupAutoConnectEnabled: false,
            queryIntervalMs: 1_000,
            createsBluetoothManager: false
        )
        service.applyDrivingSettings(.defaults)
        XCTAssertEqual(service.effectiveQueryInterval, 1.0, accuracy: 0.0001)

        service.beginForegroundSession()
        service.setBackgroundTelemetrySustained(true)
        XCTAssertEqual(service.effectiveQueryInterval, 1.0, accuracy: 0.0001, "前台不应降频")

        service.pauseForBackground()
        XCTAssertEqual(service.effectiveQueryInterval, 2.5, accuracy: 0.0001, "锁屏续记应按 2.5 倍降频")

        service.setBackgroundTelemetrySustained(false)
        XCTAssertEqual(service.effectiveQueryInterval, 1.0, accuracy: 0.0001, "结束行程应恢复基础间隔")
    }
}

// MARK: - 测试替身

@MainActor
private final class StubTelemetrySource: TelemetrySource {
    @Published var latestSnapshot: BmsSnapshot?
    @Published var linkState: TelemetryLinkState = .unavailable
    @Published var telemetryDeviceID: UUID?

    var telemetryOrigin: TelemetryOrigin { .local }
    var telemetryAvailability: TelemetryAvailability { .localBLE }
    var snapshotPublisher: AnyPublisher<BmsSnapshot?, Never> { $latestSnapshot.eraseToAnyPublisher() }
    var linkStatePublisher: AnyPublisher<TelemetryLinkState, Never> { $linkState.eraseToAnyPublisher() }
    var deviceIDPublisher: AnyPublisher<UUID?, Never> { $telemetryDeviceID.eraseToAnyPublisher() }
}

private struct StubRemoteProvider: RemoteTelemetryProviding {
    let result: RemoteTelemetry?
    let counter: CallCounter

    init(result: RemoteTelemetry?, counter: CallCounter) {
        self.result = result
        self.counter = counter
    }

    func fetchLatest() async throws -> RemoteTelemetry? {
        await counter.increment()
        return result
    }
}

private actor CallCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private final class MutableClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}
