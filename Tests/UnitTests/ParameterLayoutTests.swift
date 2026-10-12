import Foundation
import XCTest
@testable import ANTuRideDomain

final class ParameterLayoutTests: XCTestCase {
    // Independent, fixed fixtures: expectations never come from a production catalog/default layout.
    private let dashboardCatalog: [ParameterMetricDescriptor] = [
        .init(id: "soc", title: "SOC", source: .bms, sectionID: "vehicle", size: .wide),
        .init(id: "voltage", title: "Voltage", source: .bms, sectionID: "vehicle"),
        .init(id: "current", title: "Current", source: .bms, sectionID: "vehicle"),
        .init(id: "range", title: "Range", source: .app, sectionID: "vehicle", size: .wide),
        .init(id: "trip", title: "Trip", source: .app, sectionID: "vehicle"),
        .init(id: "rpm", title: "RPM", source: .controller, sectionID: "controller", size: .wide),
        .init(id: "motorTemp", title: "Motor temperature", source: .controller, sectionID: "controller"),
        .init(id: "controllerTemp", title: "Controller temperature", source: .controller, sectionID: "controller")
    ]

    private let batteryCatalog: [ParameterMetricDescriptor] = [
        .init(id: "cell1", title: "Cell 1", source: .bms, sectionID: "cells"),
        .init(id: "cell2", title: "Cell 2", source: .bms, sectionID: "cells"),
        .init(id: "cell3", title: "Cell 3", source: .bms, sectionID: "cells"),
        .init(id: "probe1", title: "Probe 1", source: .bms, sectionID: "temperatures"),
        .init(id: "probe2", title: "Probe 2", source: .bms, sectionID: "temperatures")
    ]

    private let controllerCatalog: [ParameterMetricDescriptor] = [
        .init(id: "rpm", title: "RPM", source: .controller, sectionID: "motion", size: .wide),
        .init(id: "speed", title: "Speed", source: .controller, sectionID: "motion"),
        .init(id: "motorTemp", title: "Motor temperature", source: .controller, sectionID: "thermal")
    ]

    private func dashboard() -> ParameterLayout {
        ParameterLayout(page: .dashboard, placements: [
            .init(metricID: "soc", sectionID: "top", size: .hero),
            .init(metricID: "range", sectionID: "top", size: .wide),
            .init(metricID: "voltage", sectionID: "vehicle"),
            .init(metricID: "current", sectionID: "vehicle"),
            .init(metricID: "trip", sectionID: "vehicle"),
            .init(metricID: "rpm", sectionID: "controller", size: .wide),
            .init(metricID: "motorTemp", sectionID: "controller")
        ])
    }

    private func battery() -> ParameterLayout {
        ParameterLayout(page: .battery, placements: [
            .init(metricID: "cell1", sectionID: "cells"),
            .init(metricID: "probe1", sectionID: "temperatures"),
            .init(metricID: "cell2", sectionID: "cells"),
            .init(metricID: "probe2", sectionID: "temperatures"),
            .init(metricID: "cell3", sectionID: "cells")
        ])
    }

    private func controller() -> ParameterLayout {
        ParameterLayout(page: .controller, placements: [
            .init(metricID: "rpm", sectionID: "motion", size: .wide),
            .init(metricID: "speed", sectionID: "motion"),
            .init(metricID: "motorTemp", sectionID: "thermal")
        ])
    }

    private func ids(_ layout: ParameterLayout, in section: String) -> [String] {
        layout.visible(in: section).map(\.metricID)
    }

    private func assertValid(_ layout: ParameterLayout, catalog: [ParameterMetricDescriptor],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(layout.isValid(catalog: catalog), file: file, line: line)
        XCTAssertEqual(layout.version, 3, file: file, line: line)
        XCTAssertEqual(Set(layout.placements.map(\.metricID)).count, layout.placements.count,
                       "Visible and hidden entries must share one unique metric ID", file: file, line: line)
    }

    func testWithinCategoryMovesBackwardWithoutChangingOtherCategories() {
        let result = battery().moving("cell3", to: "cells", at: 0, catalog: batteryCatalog)
        XCTAssertEqual(ids(result, in: "cells"), ["cell3", "cell1", "cell2"])
        XCTAssertEqual(ids(result, in: "temperatures"), ["probe1", "probe2"])
        assertValid(result, catalog: batteryCatalog)
    }

    func testWithinCategoryMovesForwardUsingPreRemovalIndex() {
        let result = battery().moving("cell1", to: "cells", at: 2, catalog: batteryCatalog)
        XCTAssertEqual(ids(result, in: "cells"), ["cell2", "cell1", "cell3"])
        XCTAssertEqual(ids(result, in: "temperatures"), ["probe1", "probe2"])
        assertValid(result, catalog: batteryCatalog)
    }

    func testWithinCategoryMovesToEndAtOriginalVisibleCount() {
        let result = battery().moving("cell1", to: "cells", at: 3, catalog: batteryCatalog)
        XCTAssertEqual(ids(result, in: "cells"), ["cell2", "cell3", "cell1"])
        assertValid(result, catalog: batteryCatalog)
    }

    func testAdjacentPreRemovalDestinationDoesNotMoveCard() {
        let saved = dashboard()
        let result = saved.moving("current", to: "vehicle", at: 2, catalog: dashboardCatalog)
        XCTAssertEqual(result, saved)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testMovingUsesVisibleIndexAndKeepsHiddenEntry() {
        let saved = ParameterLayout(page: .battery, placements: [
            .init(metricID: "cell1", sectionID: "cells"),
            .init(metricID: "cell2", sectionID: "cells", isVisible: false),
            .init(metricID: "cell3", sectionID: "cells")
        ])
        let result = saved.moving("cell1", to: "cells", at: 2, catalog: batteryCatalog)
        XCTAssertEqual(ids(result, in: "cells"), ["cell3", "cell1"])
        XCTAssertEqual(result.placement(for: "cell2"),
                       ParameterPlacement(metricID: "cell2", sectionID: "cells", isVisible: false))
        XCTAssertEqual(result.placements.count, 3)
        assertValid(result, catalog: batteryCatalog)
    }

    func testMovingRejectsNegativeAndOutOfRangeIndices() {
        let saved = dashboard()
        for index in [-1, 4, Int.max] {
            let result = saved.moving("voltage", to: "vehicle", at: index, catalog: dashboardCatalog)
            XCTAssertEqual(result, saved, "Invalid index: \(index)")
            assertValid(result, catalog: dashboardCatalog)
        }
    }

    func testBottomControllerMovesToTopWithoutCopyOrImplicitReplacement() {
        let result = dashboard().moving("rpm", to: "top", at: 1, catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["soc", "rpm", "range"])
        XCTAssertEqual(ids(result, in: "controller"), ["motorTemp"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip"])
        XCTAssertEqual(result.placements.count, 7)
        XCTAssertEqual(result.placement(for: "rpm")?.size, .wide)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testTopBMSMovesToVehicleAndRestoresCatalogSizeWithoutCopy() {
        let result = dashboard().moving("soc", to: "vehicle", at: 1, catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["range"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "soc", "current", "trip"])
        XCTAssertEqual(result.placement(for: "soc")?.size, .wide)
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testTopAPPMovesToVehicleWithoutCopy() {
        let result = dashboard().moving("range", to: "vehicle", at: 3, catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["soc"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip", "range"])
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testControllerMovesBackFromTopToItsOwnSource() {
        let promoted = dashboard().moving("rpm", to: "top", at: 0, catalog: dashboardCatalog)
        assertValid(promoted, catalog: dashboardCatalog)
        let result = promoted.moving("rpm", to: "controller", at: 1, catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["soc", "range"])
        XCTAssertEqual(ids(result, in: "controller"), ["motorTemp", "rpm"])
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testDashboardRejectsCrossSourceAndUnknownCategoryMoves() {
        let saved = dashboard()
        let attempts = [("rpm", "vehicle"), ("voltage", "controller"),
                        ("range", "controller"), ("soc", "cells")]
        for (metric, section) in attempts {
            XCTAssertFalse(saved.canMove(metric, to: section, catalog: dashboardCatalog))
            let result = saved.moving(metric, to: section, at: 0, catalog: dashboardCatalog)
            XCTAssertEqual(result, saved)
            assertValid(result, catalog: dashboardCatalog)
        }
    }

    func testUnknownAndHiddenCardsCannotMove() {
        let hidden = dashboard().settingVisibility(false, for: "voltage", catalog: dashboardCatalog)
        assertValid(hidden, catalog: dashboardCatalog)
        for metric in ["unknown", "voltage"] {
            XCTAssertFalse(hidden.canMove(metric, to: "top", catalog: dashboardCatalog))
            let result = hidden.moving(metric, to: "top", at: 0, catalog: dashboardCatalog)
            XCTAssertEqual(result, hidden)
            assertValid(result, catalog: dashboardCatalog)
        }
    }

    func testTopTakesControllerCardAndReturnsOldBMSToVehicle() {
        let result = dashboard().replacing("soc", with: "rpm", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["rpm", "range"])
        XCTAssertEqual(ids(result, in: "controller"), ["motorTemp"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip", "soc"])
        XCTAssertEqual(result.placement(for: "rpm")?.size, .hero)
        XCTAssertEqual(result.placement(for: "soc")?.size, .wide)
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testTopTakesControllerCardAndReturnsOldAPPToVehicle() {
        let result = dashboard().replacing("range", with: "rpm", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["soc", "rpm"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip", "range"])
        XCTAssertEqual(ids(result, in: "controller"), ["motorTemp"])
        XCTAssertEqual(result.placement(for: "range")?.size, .wide)
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testSameSourceReturnReusesTakenCardsOriginalMiddlePosition() {
        let result = dashboard().replacing("soc", with: "current", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["current", "range"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "soc", "trip"])
        XCTAssertEqual(result.placements.map(\.metricID),
                       ["current", "range", "voltage", "soc", "trip", "rpm", "motorTemp"])
        XCTAssertEqual(result.placement(for: "current")?.size, .hero)
        XCTAssertEqual(result.placement(for: "soc")?.size, .wide)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testAPPReturnReusesVehiclePositionEvenWhenReplacementIsBMS() {
        let result = dashboard().replacing("range", with: "current", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["soc", "current"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "range", "trip"])
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testTopReplacementSwapsMetricsAndKeepsSlotSizes() {
        let result = dashboard().replacing("soc", with: "range", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["range", "soc"])
        XCTAssertEqual(result.placement(for: "range")?.size, .hero)
        XCTAssertEqual(result.placement(for: "soc")?.size, .wide)
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip"])
        XCTAssertEqual(ids(result, in: "controller"), ["rpm", "motorTemp"])
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testAbsentReplacementIsAddedWithoutLosingOriginalMetric() {
        let result = dashboard().replacing("soc", with: "controllerTemp", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["controllerTemp", "range"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip", "soc"])
        XCTAssertEqual(ids(result, in: "controller"), ["rpm", "motorTemp"])
        XCTAssertEqual(result.placements.count, 8)
        XCTAssertEqual(result.placement(for: "controllerTemp")?.size, .hero)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testHiddenReplacementIsConsumedOnceAndBecomesVisible() {
        let saved = dashboard().settingVisibility(false, for: "rpm", catalog: dashboardCatalog)
        assertValid(saved, catalog: dashboardCatalog)
        let result = saved.replacing("soc", with: "rpm", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["rpm", "range"])
        XCTAssertEqual(ids(result, in: "controller"), ["motorTemp"])
        XCTAssertEqual(ids(result, in: "vehicle"), ["voltage", "current", "trip", "soc"])
        XCTAssertEqual(result.placement(for: "rpm")?.isVisible, true)
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testHiddenOrUnknownReplacementTargetAndUnknownReplacementAreNoOps() {
        let hidden = dashboard().settingVisibility(false, for: "soc", catalog: dashboardCatalog)
        assertValid(hidden, catalog: dashboardCatalog)
        let attempts = [("soc", "rpm"), ("unknown", "rpm"),
                        ("range", "unknown"), ("range", "range")]
        for (metric, replacement) in attempts {
            let result = hidden.replacing(metric, with: replacement, catalog: dashboardCatalog)
            XCTAssertEqual(result, hidden)
            assertValid(result, catalog: dashboardCatalog)
        }
    }

    func testBottomReplacementRejectsIncompatibleSource() {
        let saved = dashboard()
        let result = saved.replacing("voltage", with: "rpm", catalog: dashboardCatalog)
        XCTAssertEqual(result, saved)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testBottomReplacementSwapsExistingMetricsAndUsesDescriptorSizes() {
        let saved = ParameterLayout(page: .dashboard, placements: [
            .init(metricID: "soc", sectionID: "vehicle", size: .wide),
            .init(metricID: "voltage", sectionID: "vehicle")
        ])
        let result = saved.replacing("soc", with: "voltage", catalog: dashboardCatalog)
        XCTAssertEqual(result.placements, [
            .init(metricID: "voltage", sectionID: "vehicle"),
            .init(metricID: "soc", sectionID: "vehicle", size: .wide)
        ])
        assertValid(result, catalog: dashboardCatalog)
    }

    func testAddingVisibleMetricDoesNotDuplicateOrMoveIt() {
        let saved = dashboard()
        let result = saved.adding("rpm", to: "top", catalog: dashboardCatalog)
        XCTAssertEqual(result, saved)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testAddingHiddenMetricReusesItsIdentityInRequestedSection() {
        let saved = dashboard().settingVisibility(false, for: "rpm", catalog: dashboardCatalog)
        assertValid(saved, catalog: dashboardCatalog)
        let result = saved.adding("rpm", to: "top", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "top"), ["soc", "range", "rpm"])
        XCTAssertEqual(ids(result, in: "controller"), ["motorTemp"])
        XCTAssertEqual(result.placement(for: "rpm")?.isVisible, true)
        XCTAssertEqual(result.placements.count, 7)
        assertValid(result, catalog: dashboardCatalog)
    }

    func testAddingAbsentMetricAppendsAndRejectsUnknownOrWrongSource() {
        let saved = dashboard()
        let result = saved.adding("controllerTemp", to: "controller", catalog: dashboardCatalog)
        XCTAssertEqual(ids(result, in: "controller"), ["rpm", "motorTemp", "controllerTemp"])
        XCTAssertEqual(result.placements.count, 8)
        assertValid(result, catalog: dashboardCatalog)
        for (metric, section) in [("unknown", "top"), ("controllerTemp", "vehicle")] {
            let rejected = saved.adding(metric, to: section, catalog: dashboardCatalog)
            XCTAssertEqual(rejected, saved)
            assertValid(rejected, catalog: dashboardCatalog)
        }
    }

    func testVisibilityRoundTripKeepsPlacementOrderAndSize() {
        let saved = dashboard()
        let hidden = saved.settingVisibility(false, for: "soc", catalog: dashboardCatalog)
        XCTAssertEqual(ids(hidden, in: "top"), ["range"])
        XCTAssertEqual(hidden.placements.map(\.metricID),
                       ["soc", "range", "voltage", "current", "trip", "rpm", "motorTemp"])
        XCTAssertEqual(hidden.placement(for: "soc")?.size, .hero)
        assertValid(hidden, catalog: dashboardCatalog)
        let restored = hidden.settingVisibility(true, for: "soc", catalog: dashboardCatalog)
        XCTAssertEqual(restored, saved)
        assertValid(restored, catalog: dashboardCatalog)
        let unknown = saved.settingVisibility(false, for: "unknown", catalog: dashboardCatalog)
        XCTAssertEqual(unknown, saved)
        assertValid(unknown, catalog: dashboardCatalog)
    }

    func testBatteryCategoriesCannotMixThroughMoveReplaceOrAdd() {
        let saved = battery()
        let results = [
            saved.moving("cell1", to: "temperatures", at: 0, catalog: batteryCatalog),
            saved.moving("cell1", to: "top", at: 0, catalog: batteryCatalog),
            saved.replacing("cell1", with: "probe1", catalog: batteryCatalog),
            saved.adding("cell1", to: "temperatures", catalog: batteryCatalog)
        ]
        for result in results {
            XCTAssertEqual(result, saved)
            assertValid(result, catalog: batteryCatalog)
        }
    }

    func testControllerCategoriesCannotMixButCanReorderWithinCategory() {
        let saved = controller()
        let results = [
            saved.moving("rpm", to: "thermal", at: 0, catalog: controllerCatalog),
            saved.moving("rpm", to: "top", at: 0, catalog: controllerCatalog),
            saved.replacing("rpm", with: "motorTemp", catalog: controllerCatalog),
            saved.adding("rpm", to: "thermal", catalog: controllerCatalog)
        ]
        for result in results {
            XCTAssertEqual(result, saved)
            assertValid(result, catalog: controllerCatalog)
        }
        let reordered = saved.moving("speed", to: "motion", at: 0, catalog: controllerCatalog)
        XCTAssertEqual(ids(reordered, in: "motion"), ["speed", "rpm"])
        XCTAssertEqual(ids(reordered, in: "thermal"), ["motorTemp"])
        assertValid(reordered, catalog: controllerCatalog)
    }

    func testBatteryAndControllerPagesRejectForeignSourcesEvenWithMatchingSection() {
        let foreignAPP = ParameterMetricDescriptor(id: "appCell", title: "App", source: .app, sectionID: "cells")
        let foreignController = ParameterMetricDescriptor(id: "controllerCell", title: "Controller", source: .controller, sectionID: "cells")
        let foreignBMS = ParameterMetricDescriptor(id: "bmsRPM", title: "BMS", source: .bms, sectionID: "motion")
        let cellsCatalog = batteryCatalog + [foreignAPP, foreignController]
        for descriptor in [foreignAPP, foreignController] {
            let result = battery().adding(descriptor.id, to: "cells", catalog: cellsCatalog)
            XCTAssertEqual(result, battery())
            assertValid(result, catalog: cellsCatalog)
            let invalid = ParameterLayout(page: .battery, placements: [
                .init(metricID: descriptor.id, sectionID: "cells")
            ])
            XCTAssertFalse(invalid.isValid(catalog: cellsCatalog))
        }
        let motionCatalog = controllerCatalog + [foreignBMS]
        let result = controller().adding("bmsRPM", to: "motion", catalog: motionCatalog)
        XCTAssertEqual(result, controller())
        assertValid(result, catalog: motionCatalog)
        XCTAssertFalse(ParameterLayout(page: .controller, placements: [
            .init(metricID: "bmsRPM", sectionID: "motion")
        ]).isValid(catalog: motionCatalog))
    }

    func testValidationRejectsDuplicateIdentityIncludingHiddenEntry() {
        let duplicate = ParameterLayout(page: .dashboard, placements: [
            .init(metricID: "soc", sectionID: "top", size: .hero),
            .init(metricID: "soc", sectionID: "vehicle", size: .wide, isVisible: false)
        ])
        XCTAssertFalse(duplicate.isValid(catalog: dashboardCatalog))
    }

    func testValidationRejectsUnknownMetricAndIllegalCategory() {
        let invalidLayouts = [
            ParameterLayout(page: .dashboard, placements: [.init(metricID: "unknown", sectionID: "top")]),
            ParameterLayout(page: .dashboard, placements: [.init(metricID: "rpm", sectionID: "vehicle")]),
            ParameterLayout(page: .dashboard, placements: [.init(metricID: "soc", sectionID: "controller")]),
            ParameterLayout(page: .dashboard, placements: [.init(metricID: "soc", sectionID: "other")])
        ]
        for layout in invalidLayouts {
            XCTAssertFalse(layout.isValid(catalog: dashboardCatalog))
        }
    }

    func testDecodedUnsupportedJSONVersionsAreInvalidAndCannotBeEdited() throws {
        for version in [-1, 0, 1, 2, 4, 99] {
            let json = """
            {"version":\(version),"page":"dashboard","placements":[
              {"metricID":"soc","sectionID":"top","size":"hero","isVisible":true}
            ]}
            """
            let invalid = try JSONDecoder().decode(ParameterLayout.self, from: Data(json.utf8))
            XCTAssertEqual(invalid.version, version)
            XCTAssertFalse(invalid.isValid(catalog: dashboardCatalog))
            XCTAssertEqual(invalid.moving("soc", to: "vehicle", at: 0, catalog: dashboardCatalog), invalid)
            XCTAssertEqual(invalid.replacing("soc", with: "rpm", catalog: dashboardCatalog), invalid)
            XCTAssertEqual(invalid.settingVisibility(false, for: "soc", catalog: dashboardCatalog), invalid)
            XCTAssertEqual(invalid.adding("rpm", to: "top", catalog: dashboardCatalog), invalid)
            XCTAssertEqual(invalid.including(dashboardCatalog, catalog: dashboardCatalog), invalid)
        }
    }

    func testCodableRoundTripPreservesOrderSectionsSizesAndHiddenEntries() throws {
        let saved = ParameterLayout(page: .dashboard, placements: [
            .init(metricID: "rpm", sectionID: "top", size: .hero),
            .init(metricID: "trip", sectionID: "vehicle", isVisible: false),
            .init(metricID: "current", sectionID: "vehicle"),
            .init(metricID: "soc", sectionID: "vehicle", size: .wide)
        ])
        let decoded = try JSONDecoder().decode(ParameterLayout.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        assertValid(decoded, catalog: dashboardCatalog)
    }

    func testDynamicNewChannelsAppendWithoutResettingSortedOrHiddenChannels() {
        let saved = ParameterLayout(page: .battery, placements: [
            .init(metricID: "cell2", sectionID: "cells"),
            .init(metricID: "cell1", sectionID: "cells", isVisible: false),
            .init(metricID: "probe1", sectionID: "temperatures")
        ])
        let result = saved.including(batteryCatalog, catalog: batteryCatalog)
        XCTAssertEqual(result.placements, [
            .init(metricID: "cell2", sectionID: "cells"),
            .init(metricID: "cell1", sectionID: "cells", isVisible: false),
            .init(metricID: "probe1", sectionID: "temperatures"),
            .init(metricID: "cell3", sectionID: "cells"),
            .init(metricID: "probe2", sectionID: "temperatures")
        ])
        XCTAssertEqual(ids(result, in: "cells"), ["cell2", "cell3"])
        assertValid(result, catalog: batteryCatalog)
        let repeated = result.including(batteryCatalog, catalog: batteryCatalog)
        XCTAssertEqual(repeated, result)
        assertValid(repeated, catalog: batteryCatalog)
        let fewer = result.including(Array(batteryCatalog.prefix(1)), catalog: batteryCatalog)
        XCTAssertEqual(fewer, result, "Fewer reported channels must not erase persistent preferences")
        assertValid(fewer, catalog: batteryCatalog)
    }

    func testIncludingIgnoresUnknownAlteredAndWrongPageDescriptorsWithoutDuplicates() {
        let cell3 = ParameterMetricDescriptor(id: "cell3", title: "Cell 3", source: .bms, sectionID: "cells")
        let unknown = ParameterMetricDescriptor(id: "cell99", title: "Unknown", source: .bms, sectionID: "cells")
        let altered = ParameterMetricDescriptor(id: "cell3", title: "Wrong source", source: .app, sectionID: "cells")
        let wrongPage = ParameterMetricDescriptor(id: "appCell", title: "App", source: .app, sectionID: "cells")
        let saved = ParameterLayout(page: .battery, placements: [.init(metricID: "cell1", sectionID: "cells")])
        let accepted = saved.including([unknown, altered, cell3, cell3], catalog: batteryCatalog)
        XCTAssertEqual(ids(accepted, in: "cells"), ["cell1", "cell3"])
        assertValid(accepted, catalog: batteryCatalog)
        let rejected = saved.including([wrongPage], catalog: batteryCatalog + [wrongPage])
        XCTAssertEqual(rejected, saved)
        assertValid(rejected, catalog: batteryCatalog + [wrongPage])
    }

    func testCancelDiscardsDraftWithoutChangingSavedBaseline() {
        let saved = dashboard()
        var session = ParameterEditSession(saved: saved)
        XCTAssertFalse(session.isDirty)
        session.draft = session.draft.moving("rpm", to: "top", at: 0, catalog: dashboardCatalog)
        assertValid(session.draft, catalog: dashboardCatalog)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.baseline, saved)
        session.cancel()
        XCTAssertEqual(session.draft, saved)
        XCTAssertEqual(session.baseline, saved)
        XCTAssertFalse(session.isDirty)
        assertValid(session.draft, catalog: dashboardCatalog)
    }

    func testSaveAdvancesBaselineAndLaterCancelReturnsToLastSavedDraft() {
        var session = ParameterEditSession(saved: dashboard())
        session.draft = session.draft.replacing("soc", with: "rpm", catalog: dashboardCatalog)
        assertValid(session.draft, catalog: dashboardCatalog)
        XCTAssertTrue(session.isDirty)
        let edited = session.draft
        session.markSaved()
        XCTAssertEqual(session.baseline, edited)
        XCTAssertFalse(session.isDirty)
        assertValid(session.baseline, catalog: dashboardCatalog)
        session.draft = session.draft.settingVisibility(false, for: "range", catalog: dashboardCatalog)
        assertValid(session.draft, catalog: dashboardCatalog)
        XCTAssertTrue(session.isDirty)
        session.cancel()
        XCTAssertEqual(session.draft, edited)
        XCTAssertEqual(ids(session.draft, in: "top"), ["rpm", "range"])
        XCTAssertFalse(session.isDirty)
        assertValid(session.draft, catalog: dashboardCatalog)
    }

    func testPageEditSessionsRemainIndependent() {
        let savedBattery = battery()
        var dashboardSession = ParameterEditSession(saved: dashboard())
        var batterySession = ParameterEditSession(saved: savedBattery)
        dashboardSession.draft = dashboardSession.draft.moving("rpm", to: "top", at: 0, catalog: dashboardCatalog)
        assertValid(dashboardSession.draft, catalog: dashboardCatalog)
        XCTAssertEqual(batterySession.draft, savedBattery)
        XCTAssertFalse(batterySession.isDirty)
        batterySession.draft = batterySession.draft.moving("cell3", to: "cells", at: 0, catalog: batteryCatalog)
        assertValid(batterySession.draft, catalog: batteryCatalog)
        batterySession.cancel()
        XCTAssertEqual(batterySession.draft, savedBattery)
        XCTAssertEqual(ids(dashboardSession.draft, in: "top"), ["rpm", "soc", "range"])
        XCTAssertTrue(dashboardSession.isDirty)
        assertValid(batterySession.draft, catalog: batteryCatalog)
    }
}
