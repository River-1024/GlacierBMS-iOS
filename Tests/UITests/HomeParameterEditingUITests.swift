import XCTest

/// 独立首页编辑回归；仅操作专用偏好套件，不连接真实 BLE 或改用户布局。
final class HomeParameterEditingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-settings-seeded", "--ui-test-trips-empty"]
        // 同一次测试的重新启动复用套件；不同测试互不污染。
        app.launchEnvironment["ANTURIDE_UI_TEST_HOME_SUITE"] = "UITest-Home-\(UUID().uuidString)"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testNativeSlotNavigationReplacementSaveDashboardAndRelaunch() {
        openEditor()
        XCTAssertFalse(app.switches["安卓槽位布局（27 默认槽 / 39 指标）"].exists)
        XCTAssertFalse(app.switches["home.card.speed"].exists)
        XCTAssertFalse(app.buttons["home.save"].isEnabled)
        select(metricId: "controller_rpm")
        XCTAssertTrue(slot("home.slot.top_speed").label.contains("控制器 · 转速"))
        let returned = slot("home.slot.vehicle_extra_app_gps_speed")
        scrollTo(returned)
        XCTAssertTrue(returned.label.contains("APP · GPS 速度"))
        app.buttons["home.save"].tap()
        showDashboard()
        assertDashboardSpeed(title: "控制器 · 转速")

        app.terminate()
        app.launch()
        assertDashboardSpeed(title: "控制器 · 转速")
        openEditor()
        XCTAssertTrue(slot("home.slot.top_speed").label.contains("控制器 · 转速"))
        scrollTo(slot("home.slot.vehicle_extra_app_gps_speed"))
        XCTAssertFalse(app.buttons["home.save"].isEnabled)
        app.buttons["home.cancel"].tap()
    }

    func testCandidateBackAndEditorCancelDoNotSaveSelection() {
        openEditor()
        slot("home.slot.top_speed").tap()
        XCTAssertTrue(app.navigationBars["选择指标"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.candidate.app_gps_speed"].isEnabled)
        app.navigationBars["选择指标"].buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["home.save"].isEnabled)
        select(metricId: "bms_soc")
        XCTAssertTrue(slot("home.slot.top_speed").label.contains("BMS · 电量"))
        app.buttons["home.cancel"].tap()
        showDashboard()
        assertDashboardSpeed(title: "APP · GPS 速度")
        app.terminate()
        app.launch()
        assertDashboardSpeed(title: "APP · GPS 速度")
    }

    func testRestoreConfirmationCancelAndSave() {
        openEditor()
        select(metricId: "controller_rpm")
        app.buttons["home.save"].tap()
        openEditor()
        scrollTo(app.buttons["home.restore"])
        app.buttons["home.restore"].tap()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let cancelRestore = dialog.buttons["取消"]
        XCTAssertTrue(cancelRestore.waitForExistence(timeout: 5))
        cancelRestore.tap()
        XCTAssertFalse(app.buttons["home.save"].isEnabled)
        restoreDefaults()
        XCTAssertTrue(app.buttons["home.save"].isEnabled)
        app.buttons["home.cancel"].tap()
        showDashboard()
        assertDashboardSpeed(title: "控制器 · 转速")

        openEditor()
        restoreDefaults()
        app.buttons["home.save"].tap()
        showDashboard()
        assertDashboardSpeed(title: "APP · GPS 速度")
        app.terminate()
        app.launch()
        assertDashboardSpeed(title: "APP · GPS 速度")
        openEditor()
        XCTAssertFalse(app.buttons["home.save"].isEnabled)
        scrollTo(slot("home.slot.controller_rpm"))
        XCTAssertFalse(slot("home.slot.vehicle_extra_app_gps_speed").exists)
        app.buttons["home.cancel"].tap()
    }

    func testDashboardSlotsRemainReadOnlyWithoutHeaderOrEditingEntry() {
        XCTAssertTrue(app.scrollViews["dashboard.parameter-content"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 0)
        let soc = slot("dashboard.slot.top_soc")
        scrollTo(soc)
        soc.tap()
        XCTAssertTrue(app.scrollViews["dashboard.parameter-content"].exists)
        XCTAssertFalse(app.navigationBars["首页参数"].exists)
        XCTAssertFalse(app.navigationBars["选择指标"].exists)
        XCTAssertFalse(app.buttons["settings.home"].exists)
        XCTAssertFalse(app.buttons["home.save"].exists)
    }

    private func slot(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openEditor() {
        app.tabBars.buttons["设置"].tap()
        let entry = app.buttons["settings.home"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        scrollTo(entry)
        entry.tap()
        XCTAssertTrue(app.navigationBars["首页参数"].waitForExistence(timeout: 5))
        XCTAssertTrue(slot("home.slot.top_speed").waitForExistence(timeout: 5))
    }

    private func select(metricId: String) {
        slot("home.slot.top_speed").tap()
        XCTAssertTrue(app.navigationBars["选择指标"].waitForExistence(timeout: 5),
                      "槽位点击必须触发原生 NavigationLink 导航")
        let candidate = app.buttons["home.candidate.\(metricId)"]
        scrollTo(candidate)
        XCTAssertTrue(candidate.isEnabled)
        candidate.tap()
        XCTAssertTrue(app.navigationBars["首页参数"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["选择指标"].exists)
        XCTAssertTrue(app.buttons["home.save"].isEnabled)
    }

    private func restoreDefaults() {
        scrollTo(app.buttons["home.restore"])
        app.buttons["home.restore"].tap()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let confirmation = dialog.buttons["恢复默认"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
    }

    private func showDashboard() {
        app.tabBars.buttons["仪表盘"].tap()
        XCTAssertTrue(app.scrollViews["dashboard.parameter-content"].waitForExistence(timeout: 5))
    }

    private func assertDashboardSpeed(title: String) {
        let speed = slot("dashboard.slot.top_speed")
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        // 默认关闭文字说明：可见标题省略来源，但读数无障碍标签保留完整来源。
        let visibleTitle = title.components(separatedBy: " · ").last ?? title
        XCTAssertTrue(speed.staticTexts[visibleTitle].waitForExistence(timeout: 5),
                      "Dashboard 必须显示已保存的槽位指标：\(visibleTitle)")
        let readout = speed.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title)，")).firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "读数必须保留指标的精确来源标题：\(title)")
        XCTAssertFalse(slot("dashboard.card.speed").exists)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<16 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTFail("未找到可交互元素：\(element.identifier)")
    }
}
