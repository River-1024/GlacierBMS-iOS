import ANTuRideDomain
import Foundation
import XCTest
@testable import ANTuRide

final class HomeParameterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var prefs: HomeParameterPrefs!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "HomeParameterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        prefs = HomeParameterPrefs(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        prefs = nil
        defaults = nil
        try super.tearDownWithError()
    }

    func testDefaultConfigContainsAllCardsInStableOrderAndVisible() {
        let config = HomeParameterConfig.default

        let expected: [HomeParameterCardID] = [
            .speed, .range, .stateOfCharge, .remainingCapacity, .power,
            .current, .voltage, .capacityAndHealth, .status, .currentChart
        ]
        XCTAssertTrue(config.isValid())
        XCTAssertEqual(HomeParameterCardID.allCases, expected)
        XCTAssertEqual(config.cards.map(\.id), expected)
        XCTAssertEqual(config.visibleCardIDs, HomeParameterCardID.allCases)
        XCTAssertTrue(config.cards.allSatisfy(\.isVisible))
    }

    func testEditSessionKeepsDraftSeparateAndSupportsVisibilityOrderingSaveCancel() {
        let initial = HomeParameterConfig.default
        var session = HomeParameterEditSession.start(saved: initial)

        session = session.settingVisibility(false, for: .power)
        session = session.moving(fromOffsets: IndexSet(integer: 0), toOffset: initial.cards.count)

        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.draft.isVisible(.power))
        XCTAssertEqual(session.draft.cards.last?.id, .speed)
        XCTAssertEqual(session.baseline, initial)

        let cancelled = session.cancel()
        XCTAssertFalse(cancelled.isDirty)
        XCTAssertEqual(cancelled.draft, initial)

        let saved = session.markSaved()
        XCTAssertFalse(saved.isDirty)
        XCTAssertEqual(saved.baseline, session.draft)
    }

    func testRestoreDefaultsOnlyChangesDraft() {
        var saved = HomeParameterConfig.default
        saved = saved.settingVisibility(false, for: .status)
        saved = saved.moving(fromOffsets: IndexSet(integer: 0), toOffset: saved.cards.count)
        var session = HomeParameterEditSession.start(saved: saved)
        session = session.settingVisibility(false, for: .power)

        let restored = session.restoreDefaults()

        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(restored.baseline, saved)
        XCTAssertEqual(restored.draft, HomeParameterConfig.default)
        XCTAssertEqual(restored.cancel().draft, saved)
        XCTAssertEqual(restored.markSaved().baseline, .default)
        XCTAssertFalse(restored.markSaved().isDirty)
    }

    func testRestoringDefaultsClearsUnsavedChangesWhenBaselineIsDefault() {
        let initial = HomeParameterEditSession.start(saved: .default)
        let edited = initial.settingVisibility(false, for: .speed)
            .moving(fromOffsets: IndexSet(integer: 1), toOffset: 5)

        XCTAssertTrue(edited.isDirty)
        let restored = edited.restoreDefaults()
        XCTAssertEqual(restored, initial)
        XCTAssertFalse(restored.isDirty)
        XCTAssertEqual(initial.restoreDefaults(), initial)
    }

    func testPrefsPersistsVersionedJSONAndLoadsItBack() throws {
        var config = HomeParameterConfig.default
        config = config.settingVisibility(false, for: .currentChart)
        config = config.moving(fromOffsets: IndexSet(integer: 1), toOffset: 4)

        XCTAssertTrue(prefs.save(config))
        let raw = try XCTUnwrap(defaults.string(forKey: HomeParameterPrefs.key))
        XCTAssertTrue(raw.contains("\"version\":1"))
        XCTAssertTrue(raw.contains("\"cards\""))
        XCTAssertEqual(prefs.load(), config)
        XCTAssertEqual(HomeParameterPrefs.decode(raw), config)
    }

    func testMissingMalformedUnknownVersionAndInvalidConfigFallBackToDefaults() {
        XCTAssertEqual(prefs.load(), .default)

        for raw in [
            "not-json",
            "{\"version\":99,\"cards\":[]}",
            "{\"version\":1,\"cards\":[{\"id\":\"speed\",\"isVisible\":true}]}"
        ] {
            defaults.set(raw, forKey: HomeParameterPrefs.key)
            XCTAssertEqual(prefs.load(), .default, "raw: \(raw)")
        }
    }

    func testInvalidConfigIsNotSaved() {
        let invalid = HomeParameterConfig(cards: [HomeParameterCardPlacement(id: .speed)])

        XCTAssertFalse(prefs.save(invalid))
        XCTAssertNil(defaults.string(forKey: HomeParameterPrefs.key))
    }

    func testDefinitionsCoverExactlyTheConfigurableCards() {
        XCTAssertEqual(HomeParameterCardDefinition.all.map(\.id), HomeParameterCardID.allCases)
        for id in HomeParameterCardID.allCases {
            XCTAssertEqual(HomeParameterCardDefinition.definition(for: id).id, id)
        }
    }

    func testMoveUsesPreRemovalDestinationAndPreservesHiddenPlacement() {
        let initial = HomeParameterConfig.default.settingVisibility(false, for: .range)
        let moved = initial.moving(fromOffsets: IndexSet([1, 3]), toOffset: 7)

        XCTAssertEqual(moved.cards.map(\.id), [
            .speed, .stateOfCharge, .power, .current, .voltage,
            .range, .remainingCapacity, .capacityAndHealth, .status, .currentChart
        ])
        XCTAssertFalse(moved.isVisible(.range))
        XCTAssertTrue(moved.isValid())
        XCTAssertEqual(initial.cards[1].id, .range)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet([7, 9]), toOffset: 1).cards.map(\.id), [
            .speed, .capacityAndHealth, .currentChart, .range, .stateOfCharge,
            .remainingCapacity, .power, .current, .voltage, .status
        ])
    }

    func testMoveHandlesBeginningEndSelfDestinationAndInvalidOffsets() {
        let initial = HomeParameterConfig.default
        let last = initial.cards.count - 1
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet(integer: last), toOffset: 0).cards.first?.id, .currentChart)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet(integer: 0), toOffset: initial.cards.count).cards.last?.id, .speed)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet([1, 2]), toOffset: 2), initial)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet(), toOffset: 4), initial)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet(integer: initial.cards.count), toOffset: 0), initial)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet([0, initial.cards.count]), toOffset: 0), initial)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet(integer: 0), toOffset: -1), initial)
        XCTAssertEqual(initial.moving(fromOffsets: IndexSet(integer: 0), toOffset: initial.cards.count + 1), initial)
    }

    func testVisibleCardsFollowSavedOrderOnReloadAfterSettingsSave() {
        let edited = HomeParameterConfig.default
            .moving(fromOffsets: IndexSet(integer: 9), toOffset: 0)
            .settingVisibility(false, for: .speed)
            .settingVisibility(false, for: .power)
        let expected: [HomeParameterCardID] = [
            .currentChart, .range, .stateOfCharge, .remainingCapacity,
            .current, .voltage, .capacityAndHealth, .status
        ]
        XCTAssertTrue(prefs.save(edited))
        // Dashboard 的 AppStorage 与编辑器的 Prefs 读取同一版本化 JSON。
        let dashboardConfig = HomeParameterPrefs.decode(defaults.string(forKey: HomeParameterPrefs.key))
        XCTAssertEqual(dashboardConfig?.visibleCardIDs, expected)
        XCTAssertEqual(dashboardConfig?.visibleCards.map(\.id), expected)
        XCTAssertEqual(HomeParameterPrefs(defaults: defaults).load().visibleCardIDs, expected)
    }

    func testAllConfigurableCardsMayBeHiddenWithoutInvalidatingLayout() {
        let hidden = HomeParameterCardID.allCases.reduce(HomeParameterConfig.default) {
            $0.settingVisibility(false, for: $1)
        }
        XCTAssertTrue(hidden.isValid())
        XCTAssertTrue(hidden.visibleCardIDs.isEmpty)
        XCTAssertTrue(hidden.visibleCards.isEmpty)
        XCTAssertTrue(prefs.save(hidden))
        XCTAssertEqual(prefs.load(), hidden)
    }

    func testRestoreAndCancelDoNotPersistUntilExplicitSave() {
        let saved = HomeParameterConfig.default.settingVisibility(false, for: .status)
        XCTAssertTrue(prefs.save(saved))
        let restored = HomeParameterEditSession.start(saved: prefs.load()).restoreDefaults()

        XCTAssertEqual(prefs.load(), saved)
        XCTAssertEqual(restored.cancel().draft, saved)
        XCTAssertTrue(prefs.save(restored.draft))
        XCTAssertEqual(prefs.load(), .default)
    }

    func testDuplicateCardsAreRejectedAndInvalidSavePreservesPreviousLayout() {
        let saved = HomeParameterConfig.default.settingVisibility(false, for: .current)
        XCTAssertTrue(prefs.save(saved))
        var duplicate = HomeParameterConfig.default
        duplicate.cards[1] = duplicate.cards[0]

        XCTAssertFalse(duplicate.isValid())
        XCTAssertFalse(prefs.save(duplicate))
        XCTAssertNil(HomeParameterPrefs.encode(duplicate))
        XCTAssertEqual(prefs.load(), saved)
        XCTAssertEqual(HomeParameterEditSession.start(saved: duplicate).draft, .default)
    }
    func testAndroidSlotsAndMetricsAreUniqueAndPersistDynamicRehome() throws {
        let config = HomeParameterConfig.androidDefault
        XCTAssertEqual(HomeParameterSlotDefinition.all.count, 27)
        XCTAssertEqual(HomeParameterMetricDefinition.all.count, 39)
        XCTAssertTrue(config.isValid())
        let change = config.candidate(slotId: "top_speed", metricId: "controller_rpm")
        XCTAssertEqual(change.kind, .rehomeReplace)
        let updated = try XCTUnwrap(change.result)
        XCTAssertTrue(updated.isValid())
        XCTAssertNil(updated.metricId(for: "controller_rpm"))
        XCTAssertEqual(updated.metricId(for: "top_speed"), "controller_rpm")
        XCTAssertTrue(updated.assignments(in: .vehicle).contains { $0.metricId == "app_gps_speed" })
        XCTAssertEqual(HomeParameterPrefs.decode(HomeParameterPrefs.encode(updated)), updated.normalized())
        XCTAssertEqual(updated.candidate(slotId: "vehicle_voltage", metricId: "controller_fault").kind, .disabled)
    }

    func testBottomFaultUsesTwoColumnsWithoutDuplicatingAssignments() {
        let fault = HomeParameterAssignment(slotId: "controller_fault", metricId: "controller_fault")
        let voltage = HomeParameterAssignment(slotId: "controller_voltage", metricId: "controller_voltage")
        let rpm = HomeParameterAssignment(slotId: "controller_rpm", metricId: "controller_rpm")
        let rows = HomeParameterLayout.rows([fault, voltage, rpm], in: .controller)
        XCTAssertEqual(rows.map { $0.count }, [2, 1])
        XCTAssertEqual(rows.flatMap { $0 }.map(\.metricId), ["controller_fault", "controller_voltage", "controller_rpm"])
    }

    func testMissingControllerNeverFallsBackToBMSAndUnitsAreUnavailable() {
        for metric in HomeParameterMetricDefinition.all where metric.source == .controller {
            let value = HomeParameterReadout.read(metricId: metric.id)
            XCTAssertEqual(value.value, "--", metric.id)
            XCTAssertTrue(value.unit.isEmpty, metric.id)
        }
        XCTAssertEqual(HomeParameterReadout.read(metricId: "app_average_speed", averageSpeedKmh: 24).value, "24.0")
        XCTAssertEqual(HomeParameterReadout.read(metricId: "bms_rssi", bmsRSSI: -66).value, "-66")
    }

    func testTemperatureSelectionAndThresholdsUseSavedSettings() {
        let snapshot = BmsSnapshot(totalVoltage: 72, current: 4, soc: 12, capacityAh: 134,
            remainingAh: 50, temperatures: [30, 46], mosTemperature: 40,
            balancerTemperature: 35, cellVoltagesMillivolts: [3500, 3550], power: 4000,
            voltageDiffMillivolts: 50)
        var settings = DrivingSettings.defaults
        settings.temperatureSource = "1"
        XCTAssertEqual(HomeMetricPresentation.temperature(snapshot, settings: settings), 30)
        XCTAssertEqual(HomeMetricPresentation.tone("bms_temperature", snapshot: snapshot, speedKmh: nil, settings: settings), .green)
        settings.temperatureSource = String(Int.min)
        XCTAssertEqual(HomeMetricPresentation.temperature(snapshot, settings: settings), 46)
        settings.temperatureSource = "99"
        XCTAssertEqual(HomeMetricPresentation.temperature(snapshot, settings: settings), 46)
        XCTAssertEqual(HomeMetricPresentation.tone("bms_temperature", snapshot: snapshot, speedKmh: nil, settings: settings), .red)
        XCTAssertEqual(HomeMetricPresentation.tone("bms_soc", snapshot: snapshot, speedKmh: nil, settings: settings), .yellow)
        settings.socRedUpperPercent = 15
        XCTAssertEqual(HomeMetricPresentation.tone("bms_soc", snapshot: snapshot, speedKmh: nil, settings: settings), .red)
        settings.dischargeBaseW = 4000
        XCTAssertEqual(HomeMetricPresentation.tone("bms_power", snapshot: snapshot, speedKmh: nil, settings: settings), .red)
    }


    func testHomeLoadMigratesLegacyNilAssignmentsAndPersistsSlotDefaults() throws {
        let legacy = HomeParameterConfig.default
            .settingVisibility(false, for: .speed)
            .moving(fromOffsets: IndexSet(integer: 9), toOffset: 0)
        XCTAssertTrue(prefs.save(legacy))
        let legacyRaw = try XCTUnwrap(defaults.string(forKey: HomeParameterPrefs.key))
        XCTAssertEqual(HomeParameterPrefs.decode(legacyRaw), legacy, "旧 JSON 解码保持兼容")
        XCTAssertEqual(legacy.forHome, .androidDefault, "Dashboard 解析旧配置也只能得到槽位布局")

        XCTAssertEqual(prefs.loadForHome(), .androidDefault)
        let migratedRaw = try XCTUnwrap(defaults.string(forKey: HomeParameterPrefs.key))
        XCTAssertTrue(migratedRaw.contains("\"version\":2"))
        XCTAssertEqual(HomeParameterPrefs.decode(migratedRaw), .androidDefault)
        XCTAssertEqual(HomeParameterPrefs(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
            .loadForHome(), .androidDefault)
    }

    func testHomeLoadDefaultsForMissingMalformedAndInvalidAssignments() {
        XCTAssertEqual(prefs.loadForHome(), .androidDefault)
        for raw in ["not-json", "{\"version\":99}", "{\"version\":2,\"assignments\":[]}"] {
            defaults.set(raw, forKey: HomeParameterPrefs.key)
            XCTAssertEqual(prefs.loadForHome(), .androidDefault, raw)
        }
        var invalid = HomeParameterConfig.androidDefault
        invalid.assignments = []
        XCTAssertEqual(invalid.forHome, .androidDefault)
    }

    func testHomeLoadPreservesCustomizedAssignmentsAndDynamicReturnedSlots() throws {
        let customized = try XCTUnwrap(HomeParameterConfig.androidDefault
            .candidate(slotId: "top_speed", metricId: "controller_rpm").result)
        let returned = try XCTUnwrap(customized.assignments?.first {
            $0.slotId == "vehicle_extra_app_gps_speed"
        })
        XCTAssertEqual(returned.metricId, "app_gps_speed")
        XCTAssertNil(customized.metricId(for: "controller_rpm"))
        XCTAssertTrue(prefs.save(customized))
        let raw = defaults.string(forKey: HomeParameterPrefs.key)

        XCTAssertEqual(prefs.loadForHome(), customized.normalized())
        XCTAssertEqual(customized.forHome, customized.normalized())
        XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), raw,
                       "读取有效定制不应重写持久化内容")
        XCTAssertEqual(HomeParameterPrefs(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
            .loadForHome().assignments, customized.normalized().assignments)
    }

    func testLegacyCodableWithoutAssignmentsRemainsDecodable() throws {
        let data = try JSONEncoder().encode(HomeParameterConfig.default)
        let legacy = try JSONDecoder().decode(HomeParameterConfig.self, from: data)
        XCTAssertNil(legacy.assignments)
        XCTAssertEqual(legacy, .default)
        XCTAssertEqual(legacy.forHome, .androidDefault)
        let customized = try XCTUnwrap(HomeParameterConfig.androidDefault
            .candidate(slotId: "top_speed", metricId: "controller_rpm").result)
        XCTAssertEqual(try JSONDecoder().decode(HomeParameterConfig.self,
            from: JSONEncoder().encode(customized)), customized)
    }

    func testSlotSelectionCancelSaveAndRelaunchUseOnlySavedConfiguration() throws {
        let initial = prefs.loadForHome()
        var session = HomeParameterEditSession.start(saved: initial)
        session = session.select(slotId: "top_speed", metricId: "controller_rpm")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.baseline, initial)
        XCTAssertEqual(prefs.loadForHome(), initial, "选择只修改草稿")
        XCTAssertEqual(session.cancel().draft, initial)
        XCTAssertFalse(session.cancel().isDirty)

        XCTAssertTrue(prefs.save(session.draft))
        session = session.markSaved()
        XCTAssertFalse(session.isDirty)
        let relaunchedPrefs = HomeParameterPrefs(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let relaunched = relaunchedPrefs.loadForHome()
        XCTAssertEqual(relaunched, session.baseline)
        XCTAssertEqual(relaunched.forHome.metricId(for: "top_speed"), "controller_rpm")
        XCTAssertTrue(relaunched.assignments(in: .vehicle).contains {
            $0.slotId == "vehicle_extra_app_gps_speed" && $0.metricId == "app_gps_speed"
        })
    }

    func testSlotRestoreCancelPreservesCustomizationUntilSaved() throws {
        let saved = try XCTUnwrap(HomeParameterConfig.androidDefault
            .candidate(slotId: "top_speed", metricId: "controller_rpm").result)
        XCTAssertTrue(prefs.save(saved))
        let session = HomeParameterEditSession.start(saved: prefs.loadForHome())
        let restored = session.restoreDefaults()
        XCTAssertEqual(restored.draft, .androidDefault)
        XCTAssertEqual(restored.baseline, saved)
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(restored.cancel().draft, saved)
        XCTAssertEqual(prefs.loadForHome(), saved)
        XCTAssertTrue(prefs.save(restored.draft))
        XCTAssertEqual(prefs.loadForHome(), .androidDefault)
    }


    func testLegacyAndroidV1SlotCustomizationIsNotMigratedToDefaults() throws {
        let customized = try XCTUnwrap(HomeParameterConfig.androidDefault
            .candidate(slotId: "top_speed", metricId: "bms_soc").result)
        let encoded = try XCTUnwrap(HomeParameterPrefs.encode(customized))
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload["version"] = 1
        payload.removeValue(forKey: "cards")
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        defaults.set(raw, forKey: HomeParameterPrefs.key)

        XCTAssertEqual(prefs.loadForHome(), customized)
        XCTAssertEqual(prefs.loadForHome().metricId(for: "top_speed"), "bms_soc")
        XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), raw)
    }


    func testTopSlotReadoutTitleComesFromSelectedMetricNotOriginalSlot() throws {
        let customized = try XCTUnwrap(HomeParameterConfig.androidDefault
            .candidate(slotId: "top_speed", metricId: "controller_rpm").result)
        let metricId = try XCTUnwrap(customized.metricId(for: "top_speed"))
        XCTAssertEqual(HomeParameterReadout.read(metricId: metricId).title, "控制器 · 转速")
        XCTAssertEqual(HomeParameterReadout.read(metricId: "app_gps_speed").title, "APP · GPS 速度")
        XCTAssertFalse(DrivingSettings.defaults.showTextDescriptions)
    }

}
