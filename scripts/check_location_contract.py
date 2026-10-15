"""Source wiring checks only; do not replace Swift/Xcode or device tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


class LocationContracts(unittest.TestCase):
    def setUp(self):
        self.location = source("Sources/Services/LocationService.swift")
        self.root = source("Sources/App/RootView.swift")

    def test_foreground_owns_location_without_starting_trip(self):
        activation = self.root.split("private func activateForegroundIfNeeded()", 1)[1]
        self.assertIn("location.setForegroundActive(true)", activation)
        self.assertNotIn("startTrip()", self.root)
        background = self.root.split("if phase == .background {", 1)[1].split("}", 1)[0]
        self.assertIn("location.setForegroundActive(false)", background)

    def test_trip_releases_only_its_own_demand(self):
        stop = self.location.split("public func stopUpdating()", 1)[1].split("private func reconcileUpdates", 1)[0]
        self.assertIn("demand.isRecordingTrip = false", stop)
        self.assertIn("reconcileUpdates()", stop)
        self.assertNotIn("stopUpdatingLocation()", stop)
        trip = source("Sources/Services/TripSessionService.swift")
        self.assertIn("locationService.onFix = nil", trip)
        self.assertIn("locationService.stopUpdating()", trip)

    def test_background_permission_is_trip_only(self):
        self.assertIn("manager.allowsBackgroundLocationUpdates = demand.allowsBackgroundUpdates", self.location)
        demand = source("Sources/Domain/Trip/LocationUpdateDemand.swift")
        self.assertIn("isForeground || isRecordingTrip", demand)
        self.assertIn("allowsBackgroundUpdates: Bool { isRecordingTrip }", demand)

    def test_authorization_callback_reconciles_pending_demand(self):
        callback = self.location.split("func locationManagerDidChangeAuthorization", 1)[1].split("public nonisolated func", 1)[0]
        self.assertIn("self.reconcileUpdates()", callback)
        self.assertIn("case .authorizedWhenInUse, .authorizedAlways:", self.location)
        self.assertIn("case .denied, .restricted:", self.location)
        self.assertIn("case .notDetermined:", self.location)

    def test_stop_clears_old_fix_and_ignores_queued_locations(self):
        stop = self.location.split("private func stopLocationUpdates()", 1)[1].split("private func convert", 1)[0]
        self.assertIn("isUpdating = false", stop)
        self.assertIn("lastFix = nil", stop)
        self.assertIn("guard let self, self.isUpdating else", self.location)

    def test_no_real_location_prompts_in_ui_tests(self):
        app = source("Sources/App/ANTuRideApp.swift")
        self.assertIn("LocationService(createsLocationManager: Self.createsLocationManager())", app)
        self.assertIn('$0.hasPrefix("--ui-test-")', app)
        self.assertIn("manager = createsLocationManager ? CLLocationManager() : nil", self.location)

    def test_home_speed_remains_gps_and_rejects_stale_fixes(self):
        dashboard = source("Sources/Features/Dashboard/DashboardView.swift")
        self.assertIn("guard location.isUpdating, let fix = location.lastFix", dashboard)
        self.assertIn("now.timeIntervalSince(fix.timestamp) <= 10", dashboard)
        self.assertIn("return fix.speedKmhForDisplay", dashboard)

    def test_foreground_only_does_not_log_coordinates(self):
        callback = self.location.split("didUpdateLocations locations:", 1)[1].split("didFailWithError", 1)[0]
        self.assertIn("if self.demand.isRecordingTrip", callback)
        foreground = callback.split("} else {", 1)[1]
        self.assertNotIn("fix.latitude", foreground)
        self.assertNotIn("fix.longitude", foreground)


if __name__ == "__main__":
    unittest.main(verbosity=2)

