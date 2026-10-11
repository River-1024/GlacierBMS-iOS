import XCTest

final class ANTuRideUITests: XCTestCase {
    func testLaunchSmoke() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testDashboardHasNoHeaderAndTripControlsBelongToTrips() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-trips-empty"]
        app.launch()
        XCTAssertTrue(app.scrollViews["dashboard.parameter-content"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 0, "Dashboard must not reserve a navigation header")
        XCTAssertFalse(app.buttons["trip-session.start"].exists)
        XCTAssertFalse(app.buttons["trip-session.stop"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.slot.top_speed"].exists)
        app.tabBars.buttons["\u{884C}\u{7A0B}"].tap()
        XCTAssertTrue(app.buttons["trip-session.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["trip-session.stop"].exists)
    }

    func testDashboardRemainsScrollableInLandscapeAndLargeText() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-trips-empty", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForOrientation(app, landscape: true))
        let scroll = app.scrollViews["dashboard.parameter-content"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 0)
        let target = app.descendants(matching: .any)
            .matching(identifier: "dashboard.slot.controller_fault").firstMatch
        for _ in 0..<80 {
            if target.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(target.isHittable, "Bottom parameters must remain reachable at accessibility text size")
        XCTAssertEqual(app.tabBars.buttons.count, 5)
    }

    func testTripHistoryEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-trips-empty"]
        app.launch()
        app.tabBars.buttons["行程"].tap()
        XCTAssertTrue(app.staticTexts["暂无行程"].waitForExistence(timeout: 5))
    }

    func testSavedTripNavigationAndSegments() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-trips-seeded"]
        app.launch()
        app.tabBars.buttons["行程"].tap()
        let row = app.buttons["trip-row-11111111-1111-1111-1111-111111111111"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["行程详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第 1 段 · 前台记录"].exists)
        for label in ["第 2 段 · 后台记录", "第 3 段 · 暂停", "第 4 段 · 数据缺口"] {
            let text = app.staticTexts[label]
            for _ in 0..<4 {
                if text.exists { break }
                app.swipeUp()
            }
            XCTAssertTrue(text.exists, "未找到区间：\(label)")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testFiveTabsExposeSettingsWithoutMore() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        for title in ["仪表盘", "电池", "控制器", "行程", "设置"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, title)
        }
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.tabBars.buttons["更多"].exists)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        // 横屏返回竖屏仍显示固定五标签，设置不落入系统 More。
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForOrientation(app, landscape: true))
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForOrientation(app, landscape: false))
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
    }

    func testSettingsHubHasSingleRangeEditorAndSeparateDrivingEditor() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let rangeEntry = app.buttons["settings.range"]
        XCTAssertTrue(rangeEntry.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "settings.range").count, 1)
        rangeEntry.tap()
        XCTAssertTrue(app.navigationBars["综合续航设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["range.save.settings"].exists)
        let capacity = app.textFields["range.capacity"]
        for _ in 0..<3 {
            if capacity.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(capacity.exists)
        // 导出属于结果页，不在设置页提供第二套入口。
        XCTAssertFalse(app.buttons["range.settings.export.json"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.driving"].tap()
        XCTAssertTrue(app.navigationBars["驾驶与显示设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["driving.bluetoothRefreshIntervalMs"].exists)
        XCTAssertFalse(app.textFields["driving.rangeWindowMinutes"].exists)
        XCTAssertFalse(app.textFields["driving.rangeRefreshSeconds"].exists)
    }

    func testRangeResultsRemainAccessibleFromDashboard() {
        let app = XCUIApplication()
        app.launch()
        let results = app.buttons["dashboard.range"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        results.tap()
        XCTAssertTrue(app.navigationBars["综合续航"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["range.reason"].exists)
        XCTAssertFalse(app.textFields["range.capacity"].exists)
        XCTAssertFalse(app.buttons["窗口、容量与重置"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.count, 0, "Returning to Dashboard must hide the whole navigation bar")
    }

    func testRangeDefaultsRequireConfirmationAndPreserveDrivingPreferences() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-settings-seeded"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.range"].tap()
        let oldWindow = app.staticTexts.matching(NSPredicate(format: "label == %@", "30 分钟")).firstMatch
        let oldRefresh = app.staticTexts.matching(NSPredicate(format: "label == %@", "每 45 秒")).firstMatch
        XCTAssertTrue(oldWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(oldRefresh.exists)
        app.buttons["range.restoreDefaults"].tap()
        let confirm = app.buttons["恢复并保存默认值"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(oldWindow.exists)
        XCTAssertTrue(oldRefresh.exists)
        app.buttons["range.restoreDefaults"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "15 分钟"))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "每 10 秒")).firstMatch.exists)
        XCTAssertFalse(oldWindow.exists)
        XCTAssertFalse(oldRefresh.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.driving"].tap()
        let bmsQuery = app.textFields["driving.bluetoothRefreshIntervalMs"]
        XCTAssertTrue(bmsQuery.waitForExistence(timeout: 5))
        XCTAssertEqual(bmsQuery.value as? String, "250")
    }

    func testBatteryAndControllerTabsOnlyShowTheirOwnDataAndHistoryIsSecondary() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-bluetooth-empty"]
        app.launch()
        app.tabBars.buttons["电池"].tap()
        XCTAssertTrue(app.navigationBars["电池"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["battery.noData"].exists)
        XCTAssertFalse(app.buttons["bluetooth.battery.scan"].exists)
        XCTAssertFalse(app.buttons["扫描电池"].exists)
        app.tabBars.buttons["控制器"].tap()
        XCTAssertTrue(app.navigationBars["控制器"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["controller.noData"].exists)
        XCTAssertFalse(app.buttons["controller-scan"].exists)
        XCTAssertFalse(app.buttons["扫描控制器"].exists)
        let history = app.buttons["controller.history"]
        scrollUntilVisible(history, in: app)
        history.tap()
        XCTAssertTrue(app.navigationBars["记录与历史"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["controller-record-toggle"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["控制器"].waitForExistence(timeout: 5))
    }

    func testBluetoothSettingsHasSeparateNameFiltersAndAutoConnectionControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-bluetooth-empty"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.bluetooth"].tap()
        XCTAssertTrue(app.navigationBars["蓝牙设备"].waitForExistence(timeout: 5))
        let batteryFilter = app.switches["bluetooth.battery.filter"]
        scrollUntilVisible(batteryFilter, in: app)
        XCTAssertEqual(batteryFilter.value as? String, "1")
        // Tap the switch control itself; the accessibility frame may include the full List row.
        batteryFilter.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let filterDisabled = NSPredicate(format: "value == %@", "0")
        expectation(for: filterDisabled, evaluatedWith: batteryFilter)
        waitForExpectations(timeout: 5)
        let controllerFilter = app.switches["bluetooth.controller.filter"]
        scrollUntilVisible(controllerFilter, in: app)
        XCTAssertEqual(controllerFilter.value as? String, "1", "电池过滤不改变控制器过滤")
        XCTAssertTrue(app.switches["bluetooth.controller.autoConnect"].exists)
        XCTAssertTrue(app.buttons["bluetooth.controller.scan"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.bluetooth"].tap()
        scrollUntilVisible(batteryFilter, in: app)
        XCTAssertEqual(batteryFilter.value as? String, "0", "返回页面后保留电池过滤偏好")
    }

    func testForgettingBatteryDoesNotForgetControllerAndRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-bluetooth-seeded"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.bluetooth"].tap()
        let forgetBattery = app.buttons["bluetooth.battery.forget"]
        scrollUntilVisible(forgetBattery, in: app)
        forgetBattery.tap()
        XCTAssertTrue(app.buttons["忘记设备"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(forgetBattery.exists)
        forgetBattery.tap()
        app.buttons["忘记设备"].tap()
        XCTAssertFalse(forgetBattery.exists)
        let forgetController = app.buttons["bluetooth.controller.forget"]
        scrollUntilVisible(forgetController, in: app)
        XCTAssertTrue(forgetController.exists)
        let rememberedController = app.descendants(matching: .any)["bluetooth.controller.rememberedDevice"]
        XCTAssertTrue(rememberedController.exists)
        XCTAssertTrue(rememberedController.label.contains("APT-Test-Controller"))
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "未找到可交互元素：\(element.identifier)")
    }

    private func waitForOrientation(_ app: XCUIApplication, landscape: Bool) -> Bool {
        let condition = NSPredicate { _, _ in
            let frame = app.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: condition, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
