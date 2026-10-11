import XCTest
@testable import ANTuRideDomain

final class BluetoothDevicePolicyTests: XCTestCase {
    func testNamesAreSeparatedAndServiceDoesNotOverrideNames() {
        XCTAssertTrue(BluetoothDeviceNameFilter.matches("  aNt-BMS  ", role: .battery, enabled: true))
        XCTAssertFalse(BluetoothDeviceNameFilter.matches("APT-01", role: .battery, enabled: true))
        XCTAssertTrue(BluetoothDeviceNameFilter.matches("aPt-controller", role: .controller, enabled: true))
        XCTAssertFalse(BluetoothDeviceNameFilter.matches("ANT-BMS", role: .controller, enabled: true))
        XCTAssertFalse(BluetoothDeviceNameFilter.matches("", role: .battery, enabled: true))
        XCTAssertTrue(BluetoothDeviceNameFilter.matches("", role: .controller, enabled: false))
    }

    func testEachForegroundGetsOneAttemptAfterBluetoothIsReady() {
        var policy = DeviceAutoConnectionPolicy()
        let id = UUID()
        XCTAssertNil(policy.consumeTarget(poweredOn: false, enabled: true, rememberedID: id, hasActiveSession: false))
        XCTAssertEqual(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false), id)
        XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false))
        policy.beginForegroundSession()
        XCTAssertEqual(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false), id)
    }

    func testUserDisconnectSurvivesForegroundButNotNewProcess() {
        var policy = DeviceAutoConnectionPolicy()
        let id = UUID()
        policy.suppressForRun()
        policy.beginForegroundSession()
        XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false))
        var relaunched = DeviceAutoConnectionPolicy()
        XCTAssertEqual(relaunched.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false), id)
    }

    func testManualSearchOnlySuppressesCurrentForeground() {
        var policy = DeviceAutoConnectionPolicy()
        let id = UUID()
        policy.suppressForForegroundSession()
        XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false))
        policy.beginForegroundSession()
        XCTAssertEqual(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false), id)
    }

    func testManualReconnectCanResumeAfterUserDisconnect() {
        var policy = DeviceAutoConnectionPolicy()
        let id = UUID()
        policy.suppressForRun()
        policy.allowManualConnection()
        XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false))
        policy.beginForegroundSession()
        XCTAssertEqual(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false), id)
    }

    func testDisabledMissingAndActiveSessionsDoNotConnect() {
        let id = UUID()
        let cases: [(Bool, UUID?, Bool)] = [(false, id, false), (true, nil, false), (true, id, true)]
        for (enabled, remembered, active) in cases {
            var policy = DeviceAutoConnectionPolicy()
            XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: enabled, rememberedID: remembered, hasActiveSession: active))
            // Changing preferences or finishing a session must not cause a second attempt in the same foreground.
            XCTAssertNil(policy.consumeTarget(poweredOn: true, enabled: true, rememberedID: id, hasActiveSession: false))
        }
    }

    func testRegistryRejectsCrossRoleClaimAndKeepsIndependentDevices() async {
        await MainActor.run {
            let registry = BluetoothDeviceRegistry()
            let battery = UUID(), controller = UUID()
            XCTAssertTrue(registry.claim(battery, for: .battery))
            XCTAssertTrue(registry.claim(battery, for: .battery))
            XCTAssertFalse(registry.claim(battery, for: .controller))
            XCTAssertTrue(registry.claim(controller, for: .controller))
            registry.release(battery, for: .controller)
            XCTAssertEqual(registry.owner(of: battery), .battery)
            registry.releaseAll(for: .battery)
            XCTAssertNil(registry.owner(of: battery))
            XCTAssertEqual(registry.owner(of: controller), .controller)
            XCTAssertTrue(registry.claim(battery, for: .controller))
        }
    }
}
