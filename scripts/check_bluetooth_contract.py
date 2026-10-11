"""Bluetooth/UI source contracts only: not Swift typechecking, simulator or BLE acceptance.
Run: python scripts/check_bluetooth_contract.py
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


class BluetoothSourceContracts(unittest.TestCase):
    def test_fixed_tabs_are_separated(self):
        root = source("Sources/App/RootView.swift")
        self.assertEqual(re.findall(r"\.tag\(Tab\.(\w+)\)", root),
                         ["dashboard", "battery", "controller", "trips", "settings"])
        self.assertIn("BatteryView()", root)
        self.assertIn("NavigationStack { ControllerView() }", root)
        self.assertNotIn("DeviceView()", root)

    def test_connection_management_has_one_settings_entry(self):
        settings = source("Sources/Features/Settings/SettingsView.swift")
        self.assertEqual(settings.count("BluetoothDevicesView()"), 1)
        self.assertIn('accessibilityIdentifier("settings.bluetooth")', settings)
        self.assertIn("ControllerHistoryView()", settings)
        self.assertNotIn("ControllerView()", settings)
        for file in ["Sources/Features/Battery/BatteryView.swift", "Sources/Features/Controller/ControllerView.swift"]:
            page = source(file)
            for call in [".startScan()", ".connect(to:", ".disconnect()"]:
                self.assertNotIn(call, page)

    def test_history_actions_are_secondary_and_preserved(self):
        live = source("Sources/Features/Controller/ControllerView.swift")
        history = source("Sources/Features/Controller/ControllerHistoryView.swift")
        self.assertIn("ControllerHistoryView()", live)
        for call in ["startRecording()", "stopRecording()", "savePendingRecord()", "deleteRecord(id:"]:
            self.assertNotIn(call, live)
            self.assertIn(call, history)
        self.assertIn('alert("删除控制器记录？"', history)
        self.assertIn("exportForSharing", history)

    def test_settings_controls_are_role_specific(self):
        page = source("Sources/Features/Settings/BluetoothDevicesView.swift")
        for role in ["battery", "controller"]:
            for action in ["status", "autoConnect", "filter", "scan", "disconnect", "retry", "forget"]:
                self.assertIn(f'"bluetooth.{role}.{action}"', page)
        self.assertIn("bms.stopManualScan()", page)
        self.assertIn("controller.stopManualScan()", page)
        self.assertIn("rememberedID == target.id", page)
        self.assertIn(".confirmationDialog(", page)

    def test_data_freshness_is_explicit(self):
        battery = source("Sources/Features/Battery/BatteryView.swift")
        controller = source("Sources/Features/Controller/ControllerView.swift")
        self.assertIn("bms.state == .ready && freshness.level == .fresh ? lastSnapshot : nil", battery)
        self.assertIn("controller.state == .ready", controller)
        self.assertIn("ControllerBluetoothService.responseTimeout", controller)
        for page in [battery, controller]:
            self.assertIn('return "--"', page)
            self.assertIn("请前往设置 → 蓝牙设备", page)
            self.assertNotIn(".glassCard", page)

    def test_shared_policy_does_not_mix_names_and_uuid_roles(self):
        policy = source("Sources/Domain/Bluetooth/BluetoothDevicePolicy.swift")
        self.assertIn('role == .battery ? "ant" : "apt"', policy)
        self.assertIn("guard poweredOn, !consumed, !suppressedForRun", policy)
        self.assertIn("consumed = suppressedForRun", policy)
        self.assertIn("owners[id] == nil || owners[id] == role", policy)
        self.assertIn("guard owners[id] == role", policy)

    def test_foreground_edge_does_not_reset_on_permission_dialog(self):
        root = source("Sources/App/RootView.swift")
        self.assertIn("phase == .background", root)
        self.assertIn("if !hasStartedForeground || returnedFromBackground", root)
        self.assertIn("bms.pauseForBackground()", root)
        self.assertIn("bms.beginForegroundSession()", root)
        self.assertIn("controller.beginForegroundSession()", root)

    def test_settings_saves_cannot_overwrite_other_scope(self):
        store = source("Sources/Features/Settings/DrivingSettingsView.swift")
        page = store.split("struct DrivingSettingsView: View", 1)[1]
        self.assertNotIn("$draft.bmsAutoConnectEnabled", page)
        self.assertNotIn("$draft.controllerAutoConnectEnabled", page)
        self.assertIn("saved.bmsAutoConnectEnabled = settings.bmsAutoConnectEnabled", store)
        self.assertIn("saved.controllerAutoConnectEnabled = settings.controllerAutoConnectEnabled", store)
        self.assertIn("func saveBluetoothPreferences", store)

    def test_ui_tests_use_isolated_defaults_and_no_ble_manager(self):
        app = source("Sources/App/ANTuRideApp.swift")
        tests = source("Tests/UITests/ANTuRideUITests.swift")
        for arg in ["--ui-test-bluetooth-empty", "--ui-test-bluetooth-seeded"]:
            self.assertIn(arg, app)
            self.assertIn(arg, tests)
        self.assertIn("createsBluetoothManager: createsBluetoothManager, registry: registry", app)
        self.assertIn("UITest-Controller-", app)

    def test_services_use_independent_memory_and_finite_attempts(self):
        for role, file in [("bms", "BmsBluetoothService"), ("controller", "ControllerBluetoothService")]:
            service = source(f"Sources/Services/{file}.swift")
            for key in ["lastPeripheralUUID", "lastPeripheralName", "nameFilterEnabled"]:
                self.assertIn(f"com.zjsf.anturide.{role}.{key}", service)
            self.assertIn("registry.claim", service)
            self.assertIn("registry.release", service)
            self.assertIn("uptime()", service)
            self.assertIn("func stopManualScan()", service)
            self.assertIn("func forgetDevice()", service)
            self.assertIn("func reconnectRememberedDevice()", service)
        controller = source("Sources/Services/ControllerBluetoothService.swift")
        self.assertNotIn('fail("记忆设备名称不符合 APT 过滤条件")', controller)
        self.assertIn("if let targetID = automaticConnectionTargetID { return targetID == id }", controller)


if __name__ == "__main__":
    unittest.main(verbosity=2)
