"""Range source contracts only; this is not Swift compilation or runtime validation.

Run from any directory with::

    python scripts/check_range_contract.py

The checks inspect the iOS Swift source against sibling Android constants when
available; standalone iOS CI uses a pinned numeric Android baseline instead.
They intentionally do not execute Swift, replace XCTest/XCUITest, or claim
numerical runtime behavior that has not been verified by Swift tests.
"""
from __future__ import annotations

from decimal import Decimal
from pathlib import Path
import re
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
ANDROID_MODELS = (
    ROOT.parent
    / "app/src/main/java/com/zjsf/gps_ant_bms/model/RangeEnergyModels.kt"
)
ANDROID_ESTIMATOR = (
    ROOT.parent
    / "app/src/main/java/com/zjsf/gps_ant_bms/model/WhRangeEstimator.kt"
)
# Numeric declarations verified against Android HEAD e1dd2201e3433be120687801ed8babd2d34a6d31
# on 2026-10-11. These are not runtime implementations or calibration data.
# This nested iOS repository is checked out independently by macOS CI.
ANDROID_MODELS_BASELINE = """
internal const val MIN_DRIVING_EVIDENCE_SPEED_KMH = 3.0
val maxTelemetryGapMs: Long = 10_000L
"""
ANDROID_ESTIMATOR_BASELINE = """
private const val TELEMETRY_FRESHNESS_MS = 30_000L
private const val MIN_VALID_DURATION_MS = 30_000L
private const val MIN_DISTANCE_KM = 0.2
private const val MIN_DISCHARGE_WH = 5.0
private const val MIN_NET_WH = 5.0
private const val CAPACITY_JUMP_FRACTION = 0.01
"""


def android_source_or_baseline(path: Path, baseline: str) -> str:
    return read_source(path) if path.is_file() else baseline


SWIFT_WINDOW = ROOT / "Sources/Domain/Range/RangeDrivingWindow.swift"
SWIFT_SERVICE = ROOT / "Sources/Services/RangeService.swift"
SWIFT_CURVE = ROOT / "Sources/Domain/Range/AndroidEnergyCurve.swift"

_NUMBER = r"[-+]?(?:\d[\d_]*(?:\.\d[\d_]*)?|\.\d[\d_]*)"
_NUMBER_WITH_SUFFIX = _NUMBER + r"[fFdDlL]?"


def read_source(path: Path) -> str:
    """Read source once; if an agent has not created it, retry once non-busily."""
    if not path.is_file():
        time.sleep(0.25)
    if not path.is_file():
        raise FileNotFoundError(f"required source is missing after one retry: {path}")
    return path.read_text(encoding="utf-8-sig")


def number_token(token: str) -> Decimal:
    cleaned = token.replace("_", "")
    if cleaned and cleaned[-1] in "fFdDlL":
        cleaned = cleaned[:-1]
    return Decimal(cleaned)


def swift_static_number(source: str, name: str) -> Decimal:
    pattern = (
        rf"\bstatic\s+let\s+{re.escape(name)}"
        rf"(?:\s*:\s*[^=\n]+)?\s*=\s*({_NUMBER_WITH_SUFFIX})"
    )
    match = re.search(pattern, source)
    if match is None:
        raise AssertionError(f"Swift numeric declaration not found: {name}")
    return number_token(match.group(1))


def kotlin_const_number(source: str, name: str) -> Decimal:
    pattern = (
        rf"\b(?:\w+\s+)*const\s+val\s+{re.escape(name)}"
        rf"(?:\s*:\s*[^=\n]+)?\s*=\s*({_NUMBER_WITH_SUFFIX})"
    )
    match = re.search(pattern, source)
    if match is None:
        raise AssertionError(f"Android const not found: {name}")
    return number_token(match.group(1))


def kotlin_default_number(source: str, name: str) -> Decimal:
    pattern = (
        rf"\bval\s+{re.escape(name)}\s*:\s*[^=,\n]+"
        rf"\s*=\s*({_NUMBER_WITH_SUFFIX})"
    )
    match = re.search(pattern, source)
    if match is None:
        raise AssertionError(f"Android default not found: {name}")
    return number_token(match.group(1))


def number_after(source: str, marker: str, description: str) -> Decimal:
    match = re.search(re.escape(marker) + rf"\s*({_NUMBER_WITH_SUFFIX})", source)
    if match is None:
        raise AssertionError(f"numeric literal not found after {description}")
    return number_token(match.group(1))


def balanced_block(source: str, marker: str) -> str:
    """Return a Swift/Kotlin brace block without treating strings/comments as code."""
    marker_index = source.find(marker)
    if marker_index < 0:
        raise AssertionError(f"source marker not found: {marker}")
    opening = source.find("{", marker_index)
    if opening < 0:
        raise AssertionError(f"opening brace not found after: {marker}")

    depth = 0
    state = "code"
    i = opening
    while i < len(source):
        if state == "code":
            if source.startswith("//", i):
                newline = source.find("\n", i + 2)
                i = len(source) if newline < 0 else newline + 1
                continue
            if source.startswith("/*", i):
                end = source.find("*/", i + 2)
                if end < 0:
                    raise AssertionError(f"unterminated block comment after: {marker}")
                i = end + 2
                continue
            if source.startswith('"""', i):
                state = "multiline_string"
                i += 3
                continue
            if source[i] == '"':
                state = "string"
                i += 1
                continue
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    return source[opening + 1 : i]
            i += 1
            continue

        if state == "string":
            if source[i] == "\\":
                i += 2
                continue
            if source[i] == '"':
                state = "code"
            i += 1
            continue

        if source.startswith('"""', i):
            state = "code"
            i += 3
        else:
            i += 1

    raise AssertionError(f"unclosed source block after: {marker}")


class RangeSourceContracts(unittest.TestCase):
    """Static source contracts; no Swift build, XCTest, or runtime execution."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.android_models = android_source_or_baseline(ANDROID_MODELS, ANDROID_MODELS_BASELINE)
        cls.android_estimator = android_source_or_baseline(ANDROID_ESTIMATOR, ANDROID_ESTIMATOR_BASELINE)
        cls.window = read_source(SWIFT_WINDOW)
        cls.service = read_source(SWIFT_SERVICE)
        cls.curve = read_source(SWIFT_CURVE)

    def test_standalone_android_baseline_matches_local_source_when_available(self) -> None:
        self.assertEqual(
            kotlin_const_number(self.android_models, "MIN_DRIVING_EVIDENCE_SPEED_KMH"),
            kotlin_const_number(ANDROID_MODELS_BASELINE, "MIN_DRIVING_EVIDENCE_SPEED_KMH"),
        )
        self.assertEqual(
            kotlin_default_number(self.android_models, "maxTelemetryGapMs"),
            kotlin_default_number(ANDROID_MODELS_BASELINE, "maxTelemetryGapMs"),
        )
        for name in ("TELEMETRY_FRESHNESS_MS", "MIN_VALID_DURATION_MS", "MIN_DISTANCE_KM",
                     "MIN_DISCHARGE_WH", "MIN_NET_WH", "CAPACITY_JUMP_FRACTION"):
            self.assertEqual(kotlin_const_number(self.android_estimator, name),
                             kotlin_const_number(ANDROID_ESTIMATOR_BASELINE, name))

    def test_boundary_reset_clears_charging_and_metrics_share_prediction_batch(self) -> None:
        discard = balanced_block(self.service, "private func discardDrivingEvidence()")
        metrics = balanced_block(self.service, "private func updateWindowMetrics()")
        self.assertIn("stationaryCharging = false", discard)
        self.assertIn("let sampled = (cachedWindow ?? window).summary", metrics)
        self.assertIn("sampled.netWh / (sampled.distanceMeters / 1_000)", metrics)
        self.assertIn("6_371_008.8", self.service)

    def test_android_thresholds_are_numeric_and_mirrored(self) -> None:
        """Mirror Android's actual constants, including the km-to-m conversion."""
        speed = kotlin_const_number(
            self.android_models, "MIN_DRIVING_EVIDENCE_SPEED_KMH"
        )
        duration_ms = kotlin_const_number(self.android_estimator, "MIN_VALID_DURATION_MS")
        distance_km = kotlin_const_number(self.android_estimator, "MIN_DISTANCE_KM")
        discharge_wh = kotlin_const_number(self.android_estimator, "MIN_DISCHARGE_WH")
        net_wh = kotlin_const_number(self.android_estimator, "MIN_NET_WH")
        freshness_ms = kotlin_const_number(
            self.android_estimator, "TELEMETRY_FRESHNESS_MS"
        )
        capacity_jump = kotlin_const_number(
            self.android_estimator, "CAPACITY_JUMP_FRACTION"
        )
        gap_ms = kotlin_default_number(self.android_models, "maxTelemetryGapMs")

        self.assertEqual(speed, Decimal("3.0"))
        self.assertEqual(duration_ms / Decimal(1000), Decimal("30"))
        self.assertEqual(distance_km * Decimal(1000), Decimal("200"))
        self.assertEqual(discharge_wh, Decimal("5.0"))
        self.assertEqual(net_wh, Decimal("5.0"))
        self.assertEqual(freshness_ms / Decimal(1000), Decimal("30"))
        self.assertEqual(gap_ms / Decimal(1000), Decimal("10"))
        self.assertEqual(capacity_jump * Decimal(100), Decimal("1"))

        self.assertEqual(
            swift_static_number(self.window, "minimumAverageSpeedKmh"), speed
        )
        self.assertEqual(
            swift_static_number(self.window, "minimumPredictionDuration"),
            duration_ms / Decimal(1000),
        )
        self.assertEqual(
            swift_static_number(self.window, "minimumPredictionDistanceMeters"),
            distance_km * Decimal(1000),
        )
        self.assertEqual(
            swift_static_number(self.window, "minimumPredictionDischargeWh"),
            discharge_wh,
        )
        self.assertEqual(
            swift_static_number(self.window, "minimumPredictionNetWh"), net_wh
        )
        self.assertEqual(
            swift_static_number(self.window, "maximumIntervalDuration"),
            gap_ms / Decimal(1000),
        )
        self.assertEqual(
            swift_static_number(self.service, "telemetryMaxAge"),
            freshness_ms / Decimal(1000),
        )
        self.assertEqual(
            swift_static_number(self.service, "intervalMaxGap"),
            gap_ms / Decimal(1000),
        )
        self.assertEqual(
            number_after(
                self.service,
                "current.capacityAh *",
                "Swift capacity jump allowance",
            ),
            capacity_jump,
        )

    def test_android_energy_curve_is_seed_only_and_learning_stays_disabled(self) -> None:
        self.assertIn("public enum AndroidEnergyCurve", self.curve)
        self.assertIn("public static func remainingEnergyWh", self.curve)
        self.assertIn("built-in seed, not learned", self.curve)
        self.assertNotRegex(self.curve, r"\b(?:func|mutating\s+func)\s+(?:learn|calibrat\w*)\s*\(")

        self.assertIn("AndroidEnergyCurve.remainingEnergyWh(", self.service)
        self.assertIn("learning disabled", self.service)
        self.assertNotRegex(
            self.service,
            r"\b(?:learn|calibrat\w*|training|observation)\s*\(",
        )

    def test_gps_pairs_with_latest_bms_without_future_backfill(self) -> None:
        snapshot_body = balanced_block(self.service, "func ingest(snapshot: BmsSnapshot)")
        fix_body = balanced_block(self.service, "func ingest(fix: GpsFix)")
        recent_body = balanced_block(self.service, "private func isRecent(")

        self.assertIn("private var latestSnapshot: BmsSnapshot?", self.service)
        self.assertIn("guard snapshot.receivedAt <= now", snapshot_body)
        self.assertIn("let snapshot = latestSnapshot", fix_body)
        self.assertIn(
            "isRecent(snapshot.receivedAt, maxAge: bmsPairMaxAge, now: fix.timestamp)",
            fix_body,
        )
        self.assertIn("let endpoint = Endpoint(fix: fix, bms: snapshot)", fix_body)
        self.assertIn("guard fix.timestamp <= now", fix_body)
        self.assertIn("age >= 0", recent_body)
        for forbidden in ("backfill", "snapshotHistory", "bmsSamples", "interpolat"):
            self.assertNotIn(forbidden.lower(), self.service.lower())

    def test_power_uses_voltage_times_current_and_net_ah_uses_bms_delta(self) -> None:
        fix_body = balanced_block(self.service, "func ingest(fix: GpsFix)")
        interval_body = balanced_block(self.window, "public struct RangeDrivingInterval")

        self.assertIn(
            "startPowerW: previous.bms.totalVoltage * previous.bms.current",
            fix_body,
        )
        self.assertIn(
            "endPowerW: snapshot.totalVoltage * snapshot.current", fix_body
        )
        self.assertIn(
            "netAh: previous.bms.remainingAh - snapshot.remainingAh", fix_body
        )
        self.assertIn("public let measuredNetAh: Double?", interval_body)
        self.assertIn("measuredNetAh ?? electricalSpans.reduce", interval_body)

    def test_window_has_no_wall_clock_eviction(self) -> None:
        trim_body = balanced_block(self.window, "public mutating func trim(to duration: TimeInterval)")
        refresh_body = balanced_block(self.service, "func refresh(now: Date? = nil)")

        self.assertIn("var excess = summary.duration - duration", trim_body)
        for forbidden in ("Date(", "clock", "timeIntervalSinceNow", "now"):
            self.assertNotIn(forbidden, trim_body)
        self.assertNotIn("window.trim", refresh_body)
        self.assertIn("window.trim(to: windowAge)", self.service)

    def test_clear_reset_and_persistence_are_uuid_isolated(self) -> None:
        stored_body = balanced_block(self.service, "private struct StoredWindow")
        persist_body = balanced_block(self.service, "private func persistWindow()")
        restore_body = balanced_block(self.service, "private func restoreWindow(for id: UUID)")
        set_device_body = balanced_block(self.service, "func setDeviceID(_ id: UUID?)")
        clear_body = balanced_block(self.service, "func clearWindow()")
        reset_body = balanced_block(self.service, "func reset()")
        evidence_key_body = balanced_block(self.service, "private func evidenceKey(_ id: UUID)")

        for field in ("version", "deviceID", "intervals", "capacityAh"):
            self.assertIn(f"let {field}:", stored_body)
        for forbidden in ("latitude", "longitude", "GpsFix", "coordinate"):
            self.assertNotIn(forbidden.lower(), stored_body.lower())

        self.assertIn("id.uuidString", evidence_key_body)
        self.assertNotIn("capacityKey", self.service)
        self.assertIn("let key = evidenceKey(deviceID)", persist_body)
        self.assertIn("deviceID: deviceID", persist_body)
        self.assertIn("stored.deviceID == id", restore_body)
        self.assertIn("evidenceKey(id)", restore_body)
        self.assertIn("persistWindow()", set_device_body)
        self.assertIn("window.clear()", set_device_body)
        self.assertIn("restoreWindow(for: id)", set_device_body)
        self.assertIn("window.clear()", clear_body)
        self.assertIn("persistWindow()", clear_body)
        self.assertIn("stored.capacityAh", restore_body)
        self.assertIn("evidenceCapacityAh = stored.capacityAh", restore_body)
        self.assertIn("clearWindow()", reset_body)
        self.assertNotIn("removePersistentDomain", self.service)

    def test_capacity_is_derived_from_fresh_bms_and_not_manual_preferences(self) -> None:
        refresh = balanced_block(self.service, "func refresh(now: Date? = nil)")
        valid = balanced_block(self.service, "private func hasValidCapacity(_ value: BmsSnapshot)")
        ingest = balanced_block(self.service, "func ingest(snapshot: BmsSnapshot)")
        restart = balanced_block(self.service, "private func restartSampling(now: Date)")
        self.assertNotIn("updateNominalCapacityAh", self.service)
        self.assertIn("isUsable(snapshot, now: now)", refresh)
        self.assertIn("nominalCapacityAh = snapshot.capacityAh", refresh)
        self.assertIn("nominalCapacityAh = 0", refresh)
        self.assertIn("nominalCapacityAh = 0", restart)
        for check in ("value.capacityAh.isFinite", "value.capacityAh > 0",
                      "value.capacityAh <= 10_000", "value.remainingAh <= value.capacityAh"):
            self.assertIn(check, valid)
        self.assertIn("evidenceCapacityAh != snapshot.capacityAh", ingest)
        self.assertIn("discardDrivingEvidence()", ingest)
        self.assertIn("evidenceCapacityAh = snapshot.capacityAh", ingest)
        self.assertIn("android-driving-window-v2-bms-capacity", self.service)

    def test_capacity_settings_are_read_only_and_clear_only_affects_window(self) -> None:
        settings = read_source(ROOT / "Sources/Features/Settings/RangeSettingsView.swift")
        results = read_source(ROOT / "Sources/Features/Range/RangeView.swift")
        for removed in ("capacityText", "saveCapacity", "range.save.capacity", "range.reset.device"):
            self.assertNotIn(removed, settings)
        self.assertIn('accessibilityIdentifier("range.capacity.readout")', settings)
        self.assertIn('accessibilityIdentifier("range.clear.window")', settings)
        self.assertIn('LabeledContent("BMS 总容量"', settings)
        self.assertIn('LabeledContent("BMS 总容量"', results)
        self.assertNotIn("尚未设置", results)

    def test_persistence_and_exports_do_not_contain_coordinates(self) -> None:
        stored_body = balanced_block(self.service, "private struct StoredWindow")
        export_interval_body = balanced_block(
            self.service, "private struct ExportInterval: Encodable"
        )
        persist_body = balanced_block(self.service, "private func persistWindow()")

        for body in (stored_body, export_interval_body, persist_body):
            for forbidden in ("latitude", "longitude", "coordinate", "GpsFix", "latestFix"):
                self.assertNotIn(forbidden.lower(), body.lower())
        self.assertIn("intervals: window.intervals", persist_body)
        self.assertIn("intervals: window.intervals.map(ExportInterval.init)", self.service)

    def test_cadence_caches_only_the_window_and_recomputes_from_current_bms(self) -> None:
        refresh_body = balanced_block(self.service, "func refresh(now: Date? = nil)")
        cache_index = refresh_body.index("cachedWindow = window")
        predictor_index = refresh_body.index("let result = RangePredictor")

        self.assertLess(cache_index, predictor_index)
        self.assertIn("private var cachedWindow: RangeDrivingWindow?", self.service)
        self.assertIn("lastPredictionAt = now", refresh_body)
        self.assertIn("remainingAh: snapshot.remainingAh", refresh_body)
        self.assertIn("remainingEnergyWh: remainingEnergy", refresh_body)
        self.assertNotIn("remainingEnergy", refresh_body[cache_index:predictor_index])
        for forbidden in ("cachedPrediction", "cachedResult", "cachedRange"):
            self.assertNotIn(forbidden, self.service)

    def test_negative_power_remains_allowed_for_moving_intervals(self) -> None:
        electrical_body = balanced_block(self.window, "public struct RangeElectricalSpan")
        window_body = balanced_block(self.window, "public struct RangeDrivingWindow")
        append_body = balanced_block(self.window, "public mutating func append(_ interval: RangeDrivingInterval)")
        fix_body = balanced_block(self.service, "func ingest(fix: GpsFix)")

        self.assertIn("public var regenerationWh: Double", electrical_body)
        self.assertIn("if start <= 0 && end <= 0 { return 0 }", electrical_body)
        self.assertIn(
            "interval.distanceMeters >= interval.duration * (Self.minimumAverageSpeedKmh / 3.6)",
            append_body,
        )
        self.assertNotIn("interval.netWh >=", append_body)
        self.assertNotIn("interval.netWh > 0", append_body)
        self.assertIn("if window.append(interval) {", fix_body)
        accepted_branch = fix_body[fix_body.index("if window.append(interval) {") :]
        self.assertIn("stationaryCharging = false", accepted_branch)
        self.assertIn("stationaryCharging = interval.netWh < 0", fix_body)
        first_endpoint = fix_body.split("guard let previous = previousEndpoint else {", 1)[1].split("}", 1)[0]
        self.assertNotIn("stationaryCharging =", first_endpoint)
        self.assertIn("public var netWh: Double { summary.netWh }", window_body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
