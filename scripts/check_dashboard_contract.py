"""Dashboard source contracts only; these checks do NOT replace Xcode or XCUITest.
Run: python scripts/check_dashboard_contract.py
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


class DashboardSourceContracts(unittest.TestCase):
    def setUp(self):
        self.dashboard = source("Sources/Features/Dashboard/DashboardView.swift")
        self.trips = source("Sources/Features/Trips/TripHistoryView.swift")

    def test_root_has_no_header_or_connection_card(self):
        self.assertNotIn(".navigationTitle(", self.dashboard)
        self.assertNotIn("ConnectionStatusCard", self.dashboard)
        self.assertIn(".toolbar(.hidden, for: .navigationBar)", self.dashboard)
        self.assertNotIn(".ignoresSafeArea", self.dashboard)
        self.assertNotIn(".glassCard", self.dashboard)
        page = source("Sources/Features/Parameters/ParameterCardPage.swift")
        self.assertIn(".accessibilityElement(children: .contain)", page)
        self.assertIn(r'metric.\(placement.id)', page)
        self.assertIn("middleContent: AnyView(powerGraphic)", self.dashboard)

    def test_trip_controls_only_belong_to_trip_tab(self):
        self.assertNotIn("TripControlCard", self.dashboard)
        self.assertNotIn("tripSession", self.dashboard)
        for event in ("startTrip()", "stopTrip()", "retryPendingSave()"):
            self.assertIn(event, self.trips)
        for identifier in ("trip-session.card", "trip-session.start", "trip-session.stop"):
            self.assertIn(identifier, self.trips)

    def test_range_entry_restores_detail_navigation(self):
        self.assertIn("RangeView()", self.dashboard)
        self.assertIn("rangeService.prediction?.predictedRangeKm", self.dashboard)
        self.assertNotIn("rangeService.rangeKm", self.dashboard)
        self.assertIn(".toolbar(.visible, for: .navigationBar)", self.dashboard)
        self.assertIn('accessibilityIdentifier("dashboard.range")', self.dashboard)
        self.assertNotIn("ToolbarItem", self.dashboard)

    def test_charts_are_native_and_semantically_distinct(self):
        self.assertIn("import Charts", self.dashboard)
        self.assertIn("LineMark(", self.dashboard)
        self.assertIn("PointMark(", self.dashboard)
        self.assertNotIn("Canvas", self.dashboard)
        self.assertIn("snapshot.current : snapshot.power", self.dashboard)
        for modifier in (".chartXAxis", ".chartYAxisLabel", ".accessibilityValue"):
            self.assertIn(modifier, self.dashboard)

    def test_gap_rules_reject_invalid_and_non_increasing_data(self):
        self.assertIn(".isFinite", self.dashboard)
        self.assertRegex(self.dashboard, r"interval\s*>\s*0.*interval\s*<=\s*5")
        self.assertIn("previous = nil", self.dashboard)
        self.assertIn("series:", self.dashboard)

    def test_dynamic_type_and_saved_slots_are_retained(self):
        self.assertIn("@ScaledMetric", self.dashboard)
        page = source("Sources/Features/Parameters/ParameterCardPage.swift")
        catalog = source("Sources/Features/Parameters/ParameterCatalog.swift")
        self.assertIn("dynamicTypeSize.isAccessibilitySize", page)
        self.assertIn("ParameterLayoutStore(page: .dashboard)", self.dashboard)
        self.assertIn("legacy.forHome.assignments", catalog)
        self.assertIn('slot.id == "top_speed"', catalog)
        self.assertIn('slot.id == "top_range"', catalog)
        self.assertNotIn("frame(width: 290)", self.dashboard)
        self.assertNotIn("frame(height: 118)", self.dashboard)
        self.assertNotIn("minimumScaleFactor(0.3)", self.dashboard)
        model = source("Sources/Features/Home/HomeParameterModels.swift")
        slots = model.split("struct HomeParameterSlotDefinition:", 1)[1].split("static let heroIDs", 1)[0]
        self.assertEqual(len(re.findall(r'Self\(id: "(?:top|vehicle|controller)_', slots)), 27)


if __name__ == "__main__":
    unittest.main(verbosity=2)
