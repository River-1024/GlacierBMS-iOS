"""Static settings/navigation contracts; not a Swift build or runtime test.

Run from any directory: python scripts/check_settings_contract.py
Android parity checks use the sibling app sources when available.
"""
from pathlib import Path
import re
import unittest
from decimal import Decimal

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT.parent / "app/src/main/java/com/zjsf/gps_ant_bms/model/DashboardModels.kt"


def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


class SettingsSourceContracts(unittest.TestCase):
    def test_five_fixed_tabs_end_in_settings(self):
        root = source("Sources/App/RootView.swift")
        self.assertEqual(re.findall(r'\.tag\(Tab\.(\w+)\)', root),
                         ["dashboard", "battery", "controller", "trips", "settings"])
        self.assertIn('Label("设置", systemImage: "gearshape")', root)

    def test_range_settings_has_one_direct_hub_entry(self):
        hub = source("Sources/Features/Settings/SettingsView.swift")
        self.assertEqual(hub.count("RangeSettingsView()"), 1)
        self.assertNotIn("RangeView()", hub)
        for page in ("DrivingSettingsView", "HomeParameterEditorView",
                     "AccelerationView", "ControllerHistoryView", "LogViewerView"):
            self.assertEqual(hub.count(page + "("), 1, page)

    def test_range_editors_not_duplicated_in_driving(self):
        driving = source("Sources/Features/Settings/DrivingSettingsView.swift")
        page = driving.split("struct DrivingSettingsView: View", 1)[1]
        for field in ("rangeWindowMinutes", "rangeRefreshSeconds"):
            self.assertFalse('id: "' + field + '"' in page, f'Duplicate editor: {field}')
            self.assertIn("$" + ("windowMinutes" if field == "rangeWindowMinutes" else "refreshSeconds"),
                          source("Sources/Features/Settings/RangeSettingsView.swift"))

    def test_results_and_export_remain_on_dashboard(self):
        dashboard = source("Sources/Features/Dashboard/DashboardView.swift")
        self.assertTrue("RangeView()" in dashboard, "Missing range result entry on dashboard")
        self.assertFalse("HomeParameterEditorView()" in dashboard, "Home editor must stay in Settings")
        results = source("Sources/Features/Range/RangeView.swift")
        self.assertNotIn("RangeSettingsView()", results)
        self.assertIn('accessibilityIdentifier("range.export.json")', results)
        self.assertIn('accessibilityIdentifier("range.export.csv")', results)
        settings = source("Sources/Features/Settings/RangeSettingsView.swift")
        self.assertNotIn("range.exportJSON()", settings)
        self.assertNotIn("range.exportCSV()", settings)

    @unittest.skipUnless(ANDROID.is_file(), "Sibling Android checkout not available")
    def test_android_shared_defaults_match(self):
        swift = source("Sources/Domain/Settings/DrivingSettings.swift")
        android = ANDROID.read_text(encoding="utf-8-sig")
        fields = re.findall(r'public var (\w+)(?:\s*:\s*\w+)?\s*=\s*([^\r\n]+)', swift)
        self.assertEqual(len(fields), 23)
        enum_values = {".curve": "PowerDisplayMode.CURVE", ".system": "AppThemeMode.SYSTEM"}
        for name, value in fields:
            with self.subTest(field=name):
                match = re.search(r'val\s+' + name + r'\s*:\s*\w+\s*=\s*([^,\r\n]+)', android)
                self.assertIsNotNone(match, name)
                actual = match.group(1).strip()
                value = value.strip()
                if value in enum_values:
                    self.assertEqual(enum_values[value], actual)
                elif value in ("true", "false") or value.startswith('"'):
                    self.assertEqual(value, actual)
                else:
                    self.assertEqual(Decimal(value.replace("_", "")),
                                     Decimal(actual.replace("_", "").removesuffix("L")))

    @unittest.skipUnless(ANDROID.is_file(), "Sibling Android checkout not available")
    def test_android_shared_cadence_bounds_match(self):
        swift = source("Sources/Domain/Settings/DrivingSettings.swift")
        android = ANDROID.read_text(encoding="utf-8-sig")
        for name in ("rangeWindowMinutes", "rangeRefreshSeconds", "bluetoothRefreshIntervalMs"):
            with self.subTest(field=name):
                bounds = re.search(name + r'Bounds\s*=\s*(\d[\d_]*)\.\.\.(\d[\d_]*)', swift)
                clamp = re.search(name + r'\.coerceIn\((\d[\d_]*L?),\s*(\d[\d_]*L?)\)', android)
                self.assertIsNotNone(bounds)
                self.assertIsNotNone(clamp)
                clean = lambda s: int(s.replace("_", "").removesuffix("L"))
                self.assertEqual(tuple(map(clean, bounds.groups())), tuple(map(clean, clamp.groups())))


if __name__ == "__main__":
    unittest.main(verbosity=2)
