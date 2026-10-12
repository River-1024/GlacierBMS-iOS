import ANTuRideDomain
import Foundation
import XCTest
@testable import ANTuRide

/// App 级真实 UserDefaults 回归；每个 case 独立套件，不访问 standard/蓝牙。
/// Windows 无 Swift/Xcode：这些 XCTest 必须在 macOS 的 ANTuRideTests 执行。
final class ParameterLayoutStoreTests: XCTestCase {
    @MainActor
    func testFreshDashboardUsesTwentySevenUniqueHomeMetrics() throws {
        try withDefaults { defaults, suite in
            XCTAssertNil(defaults.object(forKey: HomeParameterPrefs.key))
            let store = ParameterLayoutStore(page: .dashboard, defaults: defaults)
            XCTAssertEqual(store.saved.version, 3)
            XCTAssertEqual(store.saved.page, .dashboard)
            XCTAssertEqual(store.saved.placements.map(\.metricID), defaultHomeMetricIDs)
            XCTAssertEqual(store.saved.placements.count, 27)
            XCTAssertEqual(Set(store.saved.placements.map(\.metricID)).count, 27)
            XCTAssertTrue(store.saved.placements.allSatisfy(\.isVisible))
            XCTAssertEqual(store.saved.visible(in: "top").map(\.metricID), Array(defaultHomeMetricIDs.prefix(6)))
            XCTAssertEqual(store.saved.placement(for: "app_gps_speed")?.size, .hero)
            XCTAssertEqual(store.saved.placement(for: "app_range")?.size, .wide)
            XCTAssertTrue(store.saved.isValid(catalog: store.catalog))
            XCTAssertNil(defaults.object(forKey: HomeParameterPrefs.key))
            let persisted = try XCTUnwrap(defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)))
            XCTAssertEqual(ParameterLayoutPrefs.decode(persisted, page: .dashboard), store.saved)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .dashboard, defaults: reopened).saved, store.saved)
        }
    }

    @MainActor
    func testHomeCatalogIDsAreUniqueAndHaveTheirRealSource() throws {
        try withDefaults { defaults, _ in
            let catalog = ParameterCatalog.metrics(for: .dashboard)
            let extraIDs = ["bms_capacity", "bms_balancer_temperature", "controller_throttle_voltage",
                            "controller_gear", "controller_state_bits", "controller_port_bits",
                            "controller_given_iq", "controller_feedback_iq", "controller_given_id",
                            "controller_field_weakening", "controller_history_fault_bits",
                            "controller_linear_brake_voltage"]
            XCTAssertEqual(catalog.count, 39)
            XCTAssertEqual(Set(catalog.map(\.id)), Set(defaultHomeMetricIDs + extraIDs))
            XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
            for metric in catalog {
                let expectedSource: ParameterSource = metric.id.hasPrefix("controller_") ? .controller
                    : metric.id.hasPrefix("bms_") ? .bms : .app
                XCTAssertEqual(metric.source, expectedSource, metric.id)
                XCTAssertEqual(metric.sectionID, expectedSource == .controller ? "controller" : "vehicle", metric.id)
            }
            let home = ParameterLayoutStore(page: .dashboard, defaults: defaults).saved
            for placement in home.placements where placement.sectionID != "top" {
                let descriptor = try XCTUnwrap(catalog.first { $0.id == placement.metricID })
                XCTAssertEqual(placement.sectionID, descriptor.sectionID)
            }
        }
    }

    @MainActor
    func testV2ControllerTakeoverAndAllVehicleExtrasMigrateWithoutChangingLegacyJSON() throws {
        try withDefaults { defaults, suite in
            // 固定 fixture，不通过生产 candidate()/encode()/migrating() 生成预期。
            var assignments = defaultHomeSlots.map { slot, metric in
                ["slotId": slot, "metricId": metric]
            }
            assignments.removeAll { $0["slotId"] == "controller_rpm" }
            let speedIndex = try XCTUnwrap(assignments.firstIndex { $0["slotId"] == "top_speed" })
            assignments[speedIndex]["metricId"] = "controller_rpm"
            assignments += [
                ["slotId": "vehicle_extra_app_gps_speed", "metricId": "app_gps_speed"],
                ["slotId": "vehicle_extra_bms_capacity", "metricId": "bms_capacity"],
                ["slotId": "vehicle_extra_bms_balancer_temperature", "metricId": "bms_balancer_temperature"]
            ]
            let raw = try json(["version": 2, "assignments": assignments])
            defaults.set(raw, forKey: HomeParameterPrefs.key)
            XCTAssertNotNil(HomeParameterPrefs.decode(raw))
            let store = ParameterLayoutStore(page: .dashboard, defaults: defaults)
            let expected = defaultHomeMetricIDs.enumerated().compactMap { index, id -> String? in
                if id == "controller_rpm" { return nil }
                return index == 0 ? "controller_rpm" : id
            } + ["app_gps_speed", "bms_capacity", "bms_balancer_temperature"]
            XCTAssertEqual(store.saved.placements.map(\.metricID), expected)
            XCTAssertEqual(store.saved.placements.count, 29)
            XCTAssertEqual(store.saved.placement(for: "controller_rpm"),
                           ParameterPlacement(metricID: "controller_rpm", sectionID: "top", size: .hero))
            for id in ["app_gps_speed", "bms_capacity", "bms_balancer_temperature"] {
                XCTAssertEqual(store.saved.placement(for: id), ParameterPlacement(metricID: id, sectionID: "vehicle"))
            }
            XCTAssertFalse(store.saved.visible(in: "controller").contains { $0.metricID == "controller_rpm" })
            XCTAssertEqual(Set(store.saved.placements.map(\.metricID)).count, expected.count)
            XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), raw)
            let migratedRaw = try XCTUnwrap(defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)))
            XCTAssertEqual(ParameterLayoutPrefs.decode(migratedRaw, page: .dashboard), store.saved)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .dashboard, defaults: reopened).saved, store.saved)
            XCTAssertEqual(reopened.string(forKey: HomeParameterPrefs.key), raw)
            XCTAssertEqual(reopened.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)), migratedRaw)
        }
    }

    @MainActor
    func testV1TenCardCompatibilityMigratesToHomeDefaultsAndPreservesOriginalJSON() throws {
        try withDefaults { defaults, _ in
            // v1 十卡保留 decode 兼容；与现有 forHome 合约一致，不再驱动槽位首页。
            let cards = ["currentChart", "range", "stateOfCharge", "remainingCapacity", "power", "current",
                         "voltage", "capacityAndHealth", "status", "speed"].map {
                ["id": $0, "isVisible": $0 != "speed"] as [String: Any]
            }
            let raw = try json(["version": 1, "cards": cards])
            defaults.set(raw, forKey: HomeParameterPrefs.key)
            let legacy = try XCTUnwrap(HomeParameterPrefs.decode(raw))
            XCTAssertFalse(legacy.usesSlotLayout)
            XCTAssertFalse(legacy.isVisible(.speed))
            XCTAssertEqual(legacy.cards.first?.id, .currentChart)
            let layout = ParameterLayoutPrefs(defaults: defaults).load(.dashboard)
            XCTAssertEqual(layout.placements.map(\.metricID), defaultHomeMetricIDs)
            XCTAssertTrue(layout.placements.allSatisfy(\.isVisible))
            XCTAssertEqual(layout.version, 3)
            XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), raw)
            XCTAssertEqual(ParameterLayoutPrefs(defaults: defaults).load(.dashboard), layout)
        }
    }

    @MainActor
    func testV3CustomOrderSurvivesRestartInsteadOfLegacyNormalization() throws {
        try withDefaults { defaults, suite in
            let legacyRaw = try json(["version": 2, "assignments": defaultHomeSlots.map {
                ["slotId": $0.0, "metricId": $0.1]
            }])
            defaults.set(legacyRaw, forKey: HomeParameterPrefs.key)
            let placements: [ParameterPlacement] = [
                .init(metricID: "controller_fault", sectionID: "controller", size: .wide),
                .init(metricID: "bms_voltage", sectionID: "vehicle", isVisible: false),
                .init(metricID: "controller_rpm", sectionID: "top", size: .hero),
                .init(metricID: "app_range", sectionID: "top", size: .wide),
                .init(metricID: "app_gps_speed", sectionID: "vehicle")
            ]
            let layout = ParameterLayout(page: .dashboard, placements: placements)
            XCTAssertTrue(ParameterLayoutPrefs(defaults: defaults).save(layout))
            let raw = try XCTUnwrap(defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)))
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            let store = ParameterLayoutStore(page: .dashboard, defaults: reopened)
            XCTAssertEqual(store.saved, layout)
            XCTAssertEqual(store.saved.placements, placements)
            XCTAssertEqual(ParameterLayoutPrefs.decode(raw, page: .dashboard), layout)
            XCTAssertEqual(reopened.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)), raw)
            XCTAssertEqual(reopened.string(forKey: HomeParameterPrefs.key), legacyRaw)
        }
    }

    @MainActor
    func testAllThreePagesSaveIndependently() throws {
        try withDefaults { defaults, suite in
            let prefs = ParameterLayoutPrefs(defaults: defaults)
            let dashboard = ParameterLayout(page: .dashboard, placements: [
                .init(metricID: "controller_rpm", sectionID: "top", size: .hero)
            ])
            let battery = ParameterLayout(page: .battery, placements: [
                .init(metricID: "bms_current", sectionID: "battery.pack"),
                .init(metricID: "bms_voltage", sectionID: "battery.pack", isVisible: false)
            ])
            let controller = ParameterLayout(page: .controller, placements: [
                .init(metricID: "controller_rpm", sectionID: "controller.electric"),
                .init(metricID: "controller_fault", sectionID: "controller.state", size: .wide)
            ])
            XCTAssertEqual(Set(ParameterPage.allCases.map { ParameterLayoutPrefs.key(for: $0) }).count, 3)
            XCTAssertTrue(prefs.save(dashboard))
            let dashboardRaw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard))
            XCTAssertTrue(prefs.save(battery))
            let batteryRaw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))
            XCTAssertTrue(prefs.save(controller))
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)), dashboardRaw)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), batteryRaw)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            for layout in [dashboard, battery, controller] {
                XCTAssertEqual(ParameterLayoutStore(page: layout.page, defaults: reopened).saved, layout)
            }
            XCTAssertNil(defaults.object(forKey: HomeParameterPrefs.key))
        }
    }

    @MainActor
    func testCancelDiscardsDirtyDraftWithoutWriting() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            let original = store.saved
            XCTAssertTrue(store.prefs.save(original))
            let raw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))
            store.beginEditing()
            store.move("bms_current", to: "battery.pack", at: 0)
            store.hide("bms_voltage")
            XCTAssertTrue(store.isEditing)
            XCTAssertTrue(store.isDirty)
            XCTAssertEqual(store.session?.baseline, original)
            XCTAssertEqual(store.saved, original)
            XCTAssertNotEqual(store.layout, original)
            store.cancel()
            XCTAssertNil(store.session)
            XCTAssertFalse(store.isDirty)
            XCTAssertFalse(store.isEditing)
            XCTAssertEqual(store.layout, original)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), raw)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .battery, defaults: reopened).saved, original)
        }
    }

    @MainActor
    func testCancelOnFreshPageDoesNotCreatePreferenceKey() throws {
        try withDefaults { defaults, _ in
            let store = ParameterLayoutStore(page: .controller, defaults: defaults)
            let original = store.saved
            store.beginEditing()
            store.hide("controller_rpm")
            XCTAssertTrue(store.isDirty)
            store.cancel()
            XCTAssertEqual(store.layout, original)
            XCTAssertNil(defaults.object(forKey: ParameterLayoutPrefs.key(for: .controller)))
        }
    }

    @MainActor
    func testFinishSavesDraftAndClearsSessionAcrossRestart() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            store.beginEditing()
            store.move("bms_power", to: "battery.pack", at: 0)
            store.hide("bms_current")
            let draft = store.layout
            XCTAssertEqual(draft.visible(in: "battery.pack").first?.metricID, "bms_power")
            XCTAssertEqual(draft.placement(for: "bms_current")?.isVisible, false)
            XCTAssertNil(defaults.object(forKey: ParameterLayoutPrefs.key(for: .battery)))
            XCTAssertTrue(store.finish())
            XCTAssertEqual(store.saved, draft)
            XCTAssertEqual(store.layout, draft)
            XCTAssertNil(store.session)
            XCTAssertFalse(store.isDirty)
            let raw = try XCTUnwrap(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)))
            XCTAssertEqual(ParameterLayoutPrefs.decode(raw, page: .battery), draft)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .battery, defaults: reopened).saved, draft)
        }
    }

    @MainActor
    func testFinishWithoutDirtySessionDoesNotWrite() throws {
        try withDefaults { defaults, _ in
            let store = ParameterLayoutStore(page: .controller, defaults: defaults)
            XCTAssertTrue(store.finish())
            store.beginEditing()
            store.beginEditing()
            XCTAssertFalse(store.isDirty)
            XCTAssertTrue(store.finish())
            XCTAssertNil(store.session)
            XCTAssertNil(defaults.object(forKey: ParameterLayoutPrefs.key(for: .controller)))
        }
    }

    @MainActor
    func testRestoreDefaultsOnlyChangesCurrentPageDraftAndKeepsReportedChannels() throws {
        try withDefaults { defaults, _ in
            let dashboard = ParameterLayoutStore(page: .dashboard, defaults: defaults)
            dashboard.beginEditing()
            dashboard.hide("bms_voltage")
            XCTAssertTrue(dashboard.finish())
            let controller = ParameterLayoutStore(page: .controller, defaults: defaults)
            controller.beginEditing()
            controller.hide("controller_rpm")
            XCTAssertTrue(controller.finish())
            let dashboardRaw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard))
            let controllerRaw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .controller))
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            let base = store.saved
            store.includeReportedChannels(cellCount: 2, probeCount: 2)
            store.beginEditing()
            store.move("bms_current", to: "battery.pack", at: 0)
            store.hide("bms_cell_voltage_2")
            XCTAssertTrue(store.finish())
            let customized = store.saved
            let batteryRaw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))

            store.restoreDefaults() // 非编辑状态不能改变保存布局。
            XCTAssertEqual(store.saved, customized)
            XCTAssertNil(store.session)
            store.beginEditing()
            store.hide("bms_voltage")
            store.restoreDefaults()
            XCTAssertTrue(store.isDirty)
            XCTAssertEqual(store.session?.baseline, customized)
            XCTAssertEqual(store.saved, customized)
            XCTAssertEqual(store.layout.placements.filter { !ParameterCatalog.isChannel($0.metricID) }, base.placements)
            XCTAssertEqual(store.layout.placements.filter { ParameterCatalog.isChannel($0.metricID) }.map(\.metricID),
                           ["bms_cell_voltage_1", "bms_cell_voltage_2", "bms_probe_temperature_1", "bms_probe_temperature_2"])
            XCTAssertTrue(store.layout.placements.allSatisfy(\.isVisible))
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), batteryRaw)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)), dashboardRaw)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .controller)), controllerRaw)
            XCTAssertEqual(store.prefs.load(.battery), customized)
            store.cancel()
            XCTAssertEqual(store.layout, customized)
        }
    }

    @MainActor
    func testRestoreReportedChannelsUsesNumberOrderAndCancelPreservesCustomizationUntilFinish() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            store.includeReportedChannels(cellCount: 3, probeCount: 2)
            store.beginEditing()
            // 将单体 1 放到单体 3 后，再隐藏单体 2，保存真实的非默认顺序。
            store.move("bms_cell_voltage_1", to: "battery.cells",
                       at: store.layout.visible(in: "battery.cells").count)
            store.hide("bms_cell_voltage_2")
            XCTAssertTrue(store.finish())
            let customized = store.saved
            let key = ParameterLayoutPrefs.key(for: .battery)
            let customRaw = try XCTUnwrap(defaults.string(forKey: key))
            XCTAssertEqual(customized.placements.filter { $0.metricID.hasPrefix("bms_cell_voltage_") }.map(\.metricID),
                           ["bms_cell_voltage_2", "bms_cell_voltage_3", "bms_cell_voltage_1"])
            XCTAssertEqual(customized.placement(for: "bms_cell_voltage_2")?.isVisible, false)

            // 手写编号、分类和显隐预期，不从 defaultLayout()/reportedChannels() 推导。
            let expectedChannels: [ParameterPlacement] = [
                .init(metricID: "bms_cell_voltage_1", sectionID: "battery.cells"),
                .init(metricID: "bms_cell_voltage_2", sectionID: "battery.cells"),
                .init(metricID: "bms_cell_voltage_3", sectionID: "battery.cells"),
                .init(metricID: "bms_probe_temperature_1", sectionID: "battery.temperature"),
                .init(metricID: "bms_probe_temperature_2", sectionID: "battery.temperature")
            ]
            store.beginEditing()
            store.restoreDefaults()
            XCTAssertEqual(store.layout.placements.filter { ParameterCatalog.isChannel($0.metricID) }, expectedChannels)
            XCTAssertEqual(store.layout.placement(for: "bms_cell_voltage_2")?.isVisible, true)
            XCTAssertTrue(store.isDirty)
            XCTAssertEqual(store.session?.baseline, customized)
            XCTAssertEqual(store.saved, customized)
            XCTAssertEqual(defaults.string(forKey: key), customRaw)
            XCTAssertEqual(store.prefs.load(.battery), customized)

            store.cancel()
            XCTAssertNil(store.session)
            XCTAssertEqual(store.layout, customized)
            XCTAssertEqual(defaults.string(forKey: key), customRaw)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .battery, defaults: reopened).saved, customized)

            store.beginEditing()
            store.restoreDefaults()
            XCTAssertEqual(store.layout.placements.filter { ParameterCatalog.isChannel($0.metricID) }, expectedChannels)
            let restoredDraft = store.layout
            XCTAssertTrue(store.finish())
            XCTAssertNil(store.session)
            XCTAssertEqual(store.saved, restoredDraft)
            let restoredRaw = try XCTUnwrap(defaults.string(forKey: key))
            XCTAssertNotEqual(restoredRaw, customRaw)
            XCTAssertEqual(ParameterLayoutPrefs.decode(restoredRaw, page: .battery), restoredDraft)
            let afterFinish = try XCTUnwrap(UserDefaults(suiteName: suite))
            let restarted = ParameterLayoutStore(page: .battery, defaults: afterFinish)
            XCTAssertEqual(restarted.saved, restoredDraft)
            XCTAssertEqual(restarted.saved.placements.filter { ParameterCatalog.isChannel($0.metricID) }, expectedChannels)
            XCTAssertEqual(restarted.saved.placement(for: "bms_cell_voltage_2")?.isVisible, true)
        }
    }

    @MainActor
    func testRestoreDefaultsIsPersistedOnlyByFinish() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .controller, defaults: defaults)
            let original = store.saved
            store.beginEditing()
            store.hide("controller_rpm")
            XCTAssertTrue(store.finish())
            let raw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .controller))
            store.beginEditing()
            store.restoreDefaults()
            XCTAssertEqual(store.layout, original)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .controller)), raw)
            XCTAssertTrue(store.finish())
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .controller, defaults: reopened).saved, original)
        }
    }

    @MainActor
    func testReducedChannelCountsPreserveHiddenChannelsAndTheirCustomOrder() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            store.includeReportedChannels(cellCount: 3, probeCount: 2)
            store.beginEditing()
            store.move("bms_cell_voltage_3", to: "battery.cells", at: 0)
            store.move("bms_probe_temperature_2", to: "battery.temperature", at: 0)
            store.hide("bms_cell_voltage_2")
            XCTAssertTrue(store.finish())
            let saved = store.saved
            let raw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))

            store.includeReportedChannels(cellCount: 1, probeCount: 0)
            store.includeReportedChannels(cellCount: 0, probeCount: 0)
            XCTAssertEqual(store.saved, saved)
            XCTAssertEqual(store.layout.visible(in: "battery.cells").first?.metricID, "bms_cell_voltage_3")
            XCTAssertEqual(store.layout.visible(in: "battery.temperature").first?.metricID, "bms_probe_temperature_2")
            XCTAssertEqual(store.layout.placement(for: "bms_cell_voltage_2")?.isVisible, false)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), raw)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            let restarted = ParameterLayoutStore(page: .battery, defaults: reopened)
            restarted.includeReportedChannels(cellCount: 1, probeCount: 1)
            XCTAssertEqual(restarted.saved, saved)
        }
    }

    @MainActor
    func testNewReportedChannelsAppendWithoutResettingExistingOrderOrVisibility() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            store.includeReportedChannels(cellCount: 2, probeCount: 1)
            store.beginEditing()
            store.move("bms_cell_voltage_2", to: "battery.cells", at: 0)
            store.hide("bms_cell_voltage_1")
            XCTAssertTrue(store.finish())
            let before = store.saved.placements
            store.includeReportedChannels(cellCount: 4, probeCount: 3)

            XCTAssertEqual(Array(store.saved.placements.prefix(before.count)), before)
            XCTAssertEqual(store.saved.placements.dropFirst(before.count).map(\.metricID),
                           ["bms_cell_voltage_3", "bms_cell_voltage_4", "bms_probe_temperature_2", "bms_probe_temperature_3"])
            XCTAssertEqual(store.saved.placement(for: "bms_cell_voltage_1")?.isVisible, false)
            XCTAssertTrue(store.saved.placements.dropFirst(before.count).allSatisfy(\.isVisible))
            let saved = store.saved
            store.includeReportedChannels(cellCount: 4, probeCount: 3)
            XCTAssertEqual(store.saved, saved)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .battery, defaults: reopened).saved, saved)
        }
    }

    @MainActor
    func testDiscoveryDuringDirtyDraftPersistsBaselinePlusChannelsNotDraftEdits() throws {
        try withDefaults { defaults, suite in
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            store.includeReportedChannels(cellCount: 2, probeCount: 1)
            let baseline = store.saved
            store.beginEditing()
            store.move("bms_current", to: "battery.pack", at: 0)
            store.move("bms_cell_voltage_2", to: "battery.cells", at: 0)
            store.hide("bms_cell_voltage_1")
            let dirtyDraft = store.layout
            XCTAssertTrue(store.isDirty)
            store.includeReportedChannels(cellCount: 3, probeCount: 2)
            let appended: [ParameterPlacement] = [
                .init(metricID: "bms_cell_voltage_3", sectionID: "battery.cells"),
                .init(metricID: "bms_probe_temperature_2", sectionID: "battery.temperature")
            ]
            let expectedSaved = ParameterLayout(page: .battery, placements: baseline.placements + appended)
            let expectedDraft = ParameterLayout(page: .battery, placements: dirtyDraft.placements + appended)

            XCTAssertEqual(store.saved, expectedSaved)
            XCTAssertEqual(store.session?.baseline, expectedSaved)
            XCTAssertEqual(store.layout, expectedDraft)
            XCTAssertTrue(store.isDirty)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(ParameterLayoutStore(page: .battery, defaults: reopened).saved, expectedSaved)
            XCTAssertEqual(store.saved.placement(for: "bms_cell_voltage_1")?.isVisible, true)
            XCTAssertEqual(store.layout.placement(for: "bms_cell_voltage_1")?.isVisible, false)
            let raw = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))
            store.cancel()
            XCTAssertEqual(store.layout, expectedSaved)
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), raw)
        }
    }

    @MainActor
    func testReportedChannelsDoNotWriteDashboardOrControllerPages() throws {
        try withDefaults { defaults, _ in
            for page in [ParameterPage.dashboard, .controller] {
                let store = ParameterLayoutStore(page: page, defaults: defaults)
                let saved = store.saved
                let raw = defaults.string(forKey: ParameterLayoutPrefs.key(for: page))
                store.beginEditing()
                let draft = store.layout
                store.includeReportedChannels(cellCount: 64, probeCount: 16)
                XCTAssertEqual(store.saved, saved)
                XCTAssertEqual(store.layout, draft)
                XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: page)), raw)
                XCTAssertFalse(store.isDirty)
            }
            XCTAssertNil(defaults.object(forKey: ParameterLayoutPrefs.key(for: .battery)))
        }
    }

    @MainActor
    func testWrongPageDecodeAndMislabeledPageSaveAreRejected() throws {
        try withDefaults { defaults, _ in
            let prefs = ParameterLayoutPrefs(defaults: defaults)
            let battery = ParameterLayout(page: .battery, placements: [
                .init(metricID: "bms_voltage", sectionID: "battery.pack")
            ])
            XCTAssertTrue(prefs.save(battery))
            let raw = try XCTUnwrap(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)))
            XCTAssertNil(ParameterLayoutPrefs.decode(raw, page: .dashboard))
            XCTAssertNil(ParameterLayoutPrefs.decode(raw, page: .controller))
            let mislabeled = ParameterLayout(page: .controller, placements: battery.placements)
            XCTAssertFalse(prefs.save(mislabeled))
            XCTAssertNil(ParameterLayoutPrefs.decode(try encoded(mislabeled), page: .controller))
            XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), raw)
            XCTAssertNil(defaults.object(forKey: ParameterLayoutPrefs.key(for: .controller)))
        }
    }

    @MainActor
    func testInvalidVersionIsRejectedByDecodeAndSaveWithoutOverwritingRaw() throws {
        try withDefaults { defaults, _ in
            let prefs = ParameterLayoutPrefs(defaults: defaults)
            let saved = ParameterLayout(page: .battery, placements: [
                .init(metricID: "bms_voltage", sectionID: "battery.pack")
            ])
            XCTAssertTrue(prefs.save(saved))
            let before = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))
            for version in [0, 1, 2, 4, 99] {
                let raw = try json(["version": version, "page": "battery", "placements": [
                    ["metricID": "bms_voltage", "sectionID": "battery.pack", "size": "compact", "isVisible": true]
                ]])
                let invalid = try JSONDecoder().decode(ParameterLayout.self, from: Data(raw.utf8))
                XCTAssertEqual(invalid.version, version)
                XCTAssertNil(ParameterLayoutPrefs.decode(raw, page: .battery))
                XCTAssertFalse(prefs.save(invalid))
                XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), before)
            }
        }
    }

    @MainActor
    func testDuplicateMetricIncludingHiddenDuplicateIsRejectedBySaveAndDecode() throws {
        try withDefaults { defaults, _ in
            let prefs = ParameterLayoutPrefs(defaults: defaults)
            let saved = ParameterLayout(page: .battery, placements: [
                .init(metricID: "bms_voltage", sectionID: "battery.pack")
            ])
            XCTAssertTrue(prefs.save(saved))
            let before = defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery))
            for visible in [true, false] {
                let invalid = ParameterLayout(page: .battery, placements: saved.placements + [
                    .init(metricID: "bms_voltage", sectionID: "battery.pack", isVisible: visible)
                ])
                XCTAssertFalse(prefs.save(invalid))
                XCTAssertNil(ParameterLayoutPrefs.decode(try encoded(invalid), page: .battery))
                XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .battery)), before)
            }
        }
    }

    @MainActor
    func testIllegalSourceUnknownMetricAndWrongSectionCannotSaveOrDecode() throws {
        try withDefaults { defaults, _ in
            let prefs = ParameterLayoutPrefs(defaults: defaults)
            let invalids: [ParameterLayout] = [
                .init(page: .dashboard, placements: [.init(metricID: "controller_rpm", sectionID: "vehicle")]),
                .init(page: .dashboard, placements: [.init(metricID: "bms_voltage", sectionID: "controller")]),
                .init(page: .dashboard, placements: [.init(metricID: "app_gps_speed", sectionID: "controller")]),
                .init(page: .battery, placements: [.init(metricID: "controller_rpm", sectionID: "battery.pack")]),
                .init(page: .controller, placements: [.init(metricID: "bms_voltage", sectionID: "controller.electric")]),
                .init(page: .battery, placements: [.init(metricID: "bms_voltage", sectionID: "battery.cells")]),
                .init(page: .battery, placements: [.init(metricID: "bms_cell_voltage_65", sectionID: "battery.cells")]),
                .init(page: .battery, placements: [.init(metricID: "bms_probe_temperature_17", sectionID: "battery.temperature")]),
                .init(page: .dashboard, placements: [.init(metricID: "invented", sectionID: "top")])
            ]
            for page in ParameterPage.allCases {
                XCTAssertTrue(prefs.save(ParameterCatalog.defaultLayout(for: page)))
            }
            let before = defaults.dictionaryRepresentation()
            for invalid in invalids {
                XCTAssertFalse(prefs.save(invalid), "\(invalid)")
                XCTAssertNil(ParameterLayoutPrefs.decode(try encoded(invalid), page: invalid.page))
            }
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
        }
    }

    @MainActor
    func testCorruptNewKeyFallsBackWithoutOverwritingEitherRawJSON() throws {
        try withDefaults { defaults, _ in
            let legacyRaw = try json(["version": 2, "assignments": defaultHomeSlots.map {
                ["slotId": $0.0, "metricId": $0.1 == "app_gps_speed" ? "bms_capacity" : $0.1]
            }])
            defaults.set(legacyRaw, forKey: HomeParameterPrefs.key)
            XCTAssertNotNil(HomeParameterPrefs.decode(legacyRaw))
            let expected = ["bms_capacity"] + Array(defaultHomeMetricIDs.dropFirst())
            for corrupt in ["not-json", "{", "{\"version\":99,\"page\":\"dashboard\",\"placements\":[]}"] {
                defaults.set(corrupt, forKey: ParameterLayoutPrefs.key(for: .dashboard))
                let store = ParameterLayoutStore(page: .dashboard, defaults: defaults)
                XCTAssertEqual(store.saved.placements.map(\.metricID), expected)
                XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: .dashboard)), corrupt)
                XCTAssertEqual(defaults.string(forKey: HomeParameterPrefs.key), legacyRaw)
            }
            for page in [ParameterPage.battery, .controller] {
                defaults.set("broken-\(page.rawValue)", forKey: ParameterLayoutPrefs.key(for: page))
                let store = ParameterLayoutStore(page: page, defaults: defaults)
                XCTAssertTrue(store.saved.isValid(catalog: store.catalog))
                XCTAssertFalse(store.saved.placements.isEmpty)
                XCTAssertEqual(defaults.string(forKey: ParameterLayoutPrefs.key(for: page)), "broken-\(page.rawValue)")
            }
        }
    }

    @MainActor
    func testReportedChannelCatalogUsesRealOneBasedNumbersAndProtocolLimits() throws {
        try withDefaults { defaults, _ in
            let cells = (1...64).map { "bms_cell_voltage_\($0)" }
            let probes = (1...16).map { "bms_probe_temperature_\($0)" }
            let all = ParameterCatalog.reportedChannels(cellCount: 64, probeCount: 16)
            XCTAssertEqual(all.map(\.id), cells + probes)
            XCTAssertEqual(Set(all.map(\.id)).count, 80)
            XCTAssertEqual(ParameterCatalog.reportedChannels(cellCount: Int.max, probeCount: Int.max), all)
            XCTAssertTrue(ParameterCatalog.reportedChannels(cellCount: 0, probeCount: 0).isEmpty)
            XCTAssertTrue(ParameterCatalog.reportedChannels(cellCount: Int.min, probeCount: -1).isEmpty)
            XCTAssertEqual(ParameterCatalog.reportedChannels(cellCount: 2, probeCount: 3).map(\.id),
                           ["bms_cell_voltage_1", "bms_cell_voltage_2", "bms_probe_temperature_1",
                            "bms_probe_temperature_2", "bms_probe_temperature_3"])
            let catalogChannels = ParameterCatalog.metrics(for: .battery).filter { ParameterCatalog.isChannel($0.id) }
            XCTAssertEqual(catalogChannels, all)
            for (index, metric) in all.enumerated() {
                let isCell = index < 64
                let number = isCell ? index + 1 : index - 64 + 1
                XCTAssertEqual(metric.title, isCell ? "单体 \(number)" : "探头 \(number)")
                XCTAssertEqual(metric.unit, isCell ? "mV" : "℃")
                XCTAssertEqual(metric.source, .bms)
                XCTAssertEqual(metric.sectionID, isCell ? "battery.cells" : "battery.temperature")
            }
            for id in ["bms_cell_voltage_0", "bms_cell_voltage_65", "bms_probe_temperature_0", "bms_probe_temperature_17"] {
                XCTAssertNil(ParameterCatalog.descriptor(id, on: .battery), id)
            }
            let store = ParameterLayoutStore(page: .battery, defaults: defaults)
            XCTAssertFalse(store.saved.placements.contains { ParameterCatalog.isChannel($0.metricID) })
            store.includeReportedChannels(cellCount: 100, probeCount: 100)
            XCTAssertEqual(store.saved.placements.filter { ParameterCatalog.isChannel($0.metricID) }.map(\.metricID), cells + probes)
        }
    }

    // 与生产槽位定义独立的固定协议 fixture；防止迁移和预期同时使用同一错误目录。
    private var defaultHomeSlots: [(String, String)] {
        [
            ("top_speed", "app_gps_speed"), ("top_range", "app_range"),
            ("top_remaining", "bms_remaining"), ("top_soc", "bms_soc"),
            ("top_power", "bms_power"), ("top_current", "bms_current"),
            ("vehicle_voltage", "bms_voltage"), ("vehicle_diff", "bms_diff"),
            ("vehicle_average_speed", "app_average_speed"), ("vehicle_consumption", "app_consumption"),
            ("vehicle_reference_consumption", "app_reference_consumption"), ("vehicle_temperature", "bms_temperature"),
            ("vehicle_mos_temperature", "bms_mos_temperature"), ("vehicle_cell_count", "bms_cell_count"),
            ("vehicle_rssi", "bms_rssi"), ("vehicle_status", "bms_status"),
            ("vehicle_mos_status", "bms_mos_status"), ("vehicle_soh", "bms_soh"),
            ("vehicle_runtime", "bms_runtime"), ("controller_voltage", "controller_voltage"),
            ("controller_bus_current", "controller_bus_current"), ("controller_rpm", "controller_rpm"),
            ("controller_temperature", "controller_temperature"), ("controller_motor_temperature", "controller_motor_temperature"),
            ("controller_phase_current", "controller_phase_current"), ("controller_run_state", "controller_run_state"),
            ("controller_fault", "controller_fault")
        ]
    }

    private var defaultHomeMetricIDs: [String] { defaultHomeSlots.map { $0.1 } }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func encoded(_ layout: ParameterLayout) throws -> String {
        String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "ParameterLayoutStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }
}
