"""Static parameter-card contracts ONLY, not Swift execution, typechecking or drag acceptance."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


class ParameterCardSourceContracts(unittest.TestCase):
    def test_all_three_pages_use_one_shared_editor(self):
        for page, folder in (("dashboard", "Dashboard"), ("battery", "Battery"), ("controller", "Controller")):
            text = source(f"Sources/Features/{folder}/{folder}View.swift")
            self.assertIn(f"ParameterLayoutStore(page: .{page})", text)
            self.assertIn("ParameterCardPage(store: layout", text)
            self.assertNotIn("HomeParameterEditorView", text)
        self.assertFalse((ROOT / "Sources/Features/Home/HomeParameterEditorView.swift").exists())

    def test_display_edits_do_not_write_devices(self):
        texts = [source(f"Sources/Features/{name}/{name}View.swift") for name in ("Dashboard", "Battery", "Controller")]
        texts += [source("Sources/Features/Parameters/ParameterCardPage.swift"),
                  source("Sources/Features/Parameters/ParameterLayoutStore.swift")]
        for text in texts:
            for forbidden in ("writeValue(", "setNotifyValue(", ".startScan()", ".disconnect()"):
                self.assertNotIn(forbidden, text)

    def test_page_keys_and_legacy_data_are_isolated(self):
        prefs = source("Sources/Features/Parameters/ParameterLayoutStore.swift")
        self.assertIn('"parameter_layout_v3_', prefs)
        self.assertIn("layout.page == page", prefs)
        self.assertIn("layout.isValid(catalog:", prefs)
        self.assertIn("HomeParameterPrefs.decode", prefs)
        self.assertNotIn("loadForHome()", prefs)
        self.assertNotIn("removePersistentDomain", prefs)
        self.assertNotIn("normalized()", prefs)

    def test_classification_and_metric_uniqueness_are_model_rules(self):
        model = source("Sources/Domain/Display/ParameterLayout.swift")
        self.assertIn("Set(placements.map(\\.metricID)).count == placements.count", model)
        self.assertIn('sectionID == "vehicle" && descriptor.source == .controller', model)
        self.assertIn('sectionID == "controller" && descriptor.source != .controller', model)
        self.assertIn("return sectionID == descriptor.sectionID", model)
        self.assertIn('target.sectionID == "top" && occupied.sectionID != "top"', model)
        self.assertNotIn("normalized()", model)

    def test_channel_catalog_matches_protocol_bounds(self):
        catalog = source("Sources/Features/Parameters/ParameterCatalog.swift")
        protocol = source("Sources/Domain/Protocol/AntProtocol.swift")
        self.assertIn("temperatureCount <= 16, cellCount <= 64", protocol)
        self.assertIn("min(64, max(0, cellCount))", catalog)
        self.assertIn("min(16, max(0, probeCount))", catalog)
        self.assertIn("bms_cell_voltage_", catalog)
        self.assertIn("bms_probe_temperature_", catalog)
        self.assertNotIn("controller_speed", catalog)

    def test_editing_has_cancel_save_and_accessible_move_alternatives(self):
        page = source("Sources/Features/Parameters/ParameterCardPage.swift")
        for action in ("store.cancel()", "store.finish()", "store.restoreDefaults()", "store.moveToSource", "store.moveToTop"):
            self.assertIn(action, page)
        self.assertIn(".accessibilityAction(named:", page)
        self.assertIn(".confirmationDialog(", page)
        self.assertIn(".safeAreaInset(edge: .bottom", page)
        self.assertIn(".sheet(item: $picker)", page)
        self.assertIn("dynamicTypeSize.isAccessibilitySize", page)
        self.assertNotIn("ScrollView", page)

    def test_chart_is_a_fixed_middle_item_not_a_parameter(self):
        page = source("Sources/Features/Parameters/ParameterCardPage.swift")
        self.assertIn('definition.id == "top", middleContent != nil', page)
        self.assertIn('id: "fixed.middle", isDraggable: false, fullWidth: true', page)
        dashboard = source("Sources/Features/Dashboard/DashboardView.swift")
        self.assertIn("middleContent: AnyView(powerGraphic)", dashboard)
        self.assertIn("{ rangeLink }", dashboard)

    def test_drag_stays_local_and_uses_explicit_business_permission(self):
        grid = source("Sources/DesignSystem/NativeParameterGrid.swift")
        self.assertIn("UICollectionViewDragDelegate", grid)
        self.assertIn("UICollectionViewDropDelegate", grid)
        self.assertRegex(grid, r"dragSessionIsRestrictedToDraggingApplication[\s\S]{0,100}\{\s*(?:return\s+)?true\s*\}")
        self.assertIn("token.owner === self", grid)
        self.assertIn("session.localDragSession", grid)
        self.assertIn("parent.canMove(token.cardID, destination.sectionID)", grid)
        self.assertIn("UICollectionViewDropProposal(operation: .forbidden)", grid)
        self.assertIn("parent.onMove(token.cardID", grid)

    def test_native_grid_does_not_rebuild_for_telemetry_ticks(self):
        grid = source("Sources/DesignSystem/NativeParameterGrid.swift")
        self.assertIn("UICollectionViewCompositionalLayout", grid)
        self.assertIn("UICollectionViewDiffableDataSource", grid)
        self.assertIn("UIHostingConfiguration", grid)
        self.assertIn("newStructure != structure", grid)
        self.assertNotIn(".reloadData()", grid)
        self.assertIn("refreshVisibleContent(in: collectionView)", grid)
        self.assertIn("id != activeDrag?.cardID", grid)

    def test_repeating_grid_items_fit_actual_column_width(self):
        grid = source("Sources/DesignSystem/NativeParameterGrid.swift")
        self.assertIn("availableWidth = max(1, width - 32)", grid)
        self.assertIn("(availableWidth - CGFloat(columns - 1) * 8) / CGFloat(columns)", grid)
        self.assertIn("widthDimension: .absolute(itemWidth)", grid)

    def test_navigation_routes_live_outside_hosted_cells(self):
        for folder, flag, destination in (("Dashboard", "showingRange", "RangeView"),
                                           ("Controller", "showingHistory", "ControllerHistoryView")):
            text = source(f"Sources/Features/{folder}/{folder}View.swift")
            self.assertIn(f".navigationDestination(isPresented: ${flag})", text)
            self.assertIn(f"{destination}()", text)
            self.assertNotIn("NavigationLink", text)

    def test_cards_have_semantic_scaling_and_keep_internal_buttons(self):
        card = source("Sources/DesignSystem/AppMetricCard.swift")
        self.assertIn("@ScaledMetric", card)
        self.assertIn(".monospacedDigit()", card)
        self.assertIn("ViewThatFits(in: .horizontal)", card)
        self.assertIn(".accessibilityElement(children: .contain)", card)
        self.assertNotIn("minimumScaleFactor", card)
        self.assertNotIn(".glassCard", card)

    def test_ui_test_layout_suites_match_production_isolation_gate(self):
        prefs = source("Sources/Features/Home/HomeParameterModels.swift")
        self.assertIn('suite.hasPrefix("UITest-Home-")', prefs)
        for file in ("HomeParameterEditingUITests", "ANTuRideUITests"):
            tests = source(f"Tests/UITests/{file}.swift")
            self.assertIn('"UITest-Home-', tests)
            self.assertNotIn('"UITest-Parameters-', tests)
            self.assertNotIn('"UITest-Navigation-', tests)
        tests = source("Tests/UITests/HomeParameterEditingUITests.swift")
        self.assertIn("press(forDuration:", tests)
        self.assertIn("thenDragTo:", tests)
        self.assertIn('"--ui-test-bluetooth-empty"', tests)

    def test_domain_and_persistence_have_behavioral_regressions(self):
        domain = source("Tests/UnitTests/ParameterLayoutTests.swift")
        app = source("Tests/AppTests/ParameterLayoutStoreTests.swift")
        self.assertGreaterEqual(len(re.findall(r"func test", domain)), 15)
        self.assertGreaterEqual(len(re.findall(r"func test", app)), 12)
        self.assertIn("UserDefaults(suiteName:", app)
        self.assertNotIn("XCTSkip", domain)


if __name__ == "__main__":
    unittest.main(verbosity=2)
