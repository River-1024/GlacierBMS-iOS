import XCTest

/// v3 页面编辑交互回归；隔离布局偏好并禁用 BLE，不读写真实设备或用户布局。
final class HomeParameterEditingUITests: XCTestCase {
    private var app: XCUIApplication!
    private let tabTitles = ["dashboard": "仪表盘", "battery": "电池", "controller": "控制器"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-bluetooth-empty", "--ui-test-trips-empty"]
        // 同一用例重启复用套件；不同用例不共享 v3 或 legacy 布局。
        app.launchEnvironment["ANTURIDE_UI_TEST_HOME_SUITE"] = "UITest-Home-Parameters-\(UUID().uuidString)"
        launchIsolatedApp()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testPageReplacementReturnsGPSToVehicleAndPersistsAfterRelaunch() {
        openEditor()
        replaceGPSWithRPM()
        assertBefore("controller_rpm", "app_range", page: "dashboard")
        assertReturnedGPSInVehicle()
        save()
        relaunch()
        openEditor()
        assertBefore("controller_rpm", "app_range", page: "dashboard")
        assertReturnedGPSInVehicle()
        cancel()
    }

    func testCandidateCancelAndPageCancelDoNotPersistReplacement() {
        openEditor()
        chooseAction("替换参数", metricID: "app_gps_speed")
        XCTAssertTrue(app.navigationBars["替换参数"].waitForExistence(timeout: 5))
        let unchanged = app.buttons.matching(identifier: "dashboard.candidate.app_gps_speed").firstMatch
        scrollPickerTo(unchanged)
        XCTAssertFalse(unchanged.isEnabled)
        app.navigationBars["替换参数"].buttons["取消"].tap()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        replaceGPSWithRPM()
        cancel()
        relaunch()
        openEditor()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        scrollTo(metric("controller_rpm"), page: "dashboard")
        XCTAssertTrue(metric("controller_rpm").isHittable)
        cancel()
    }

    func testRestoreConfirmationCancelAndUnsavedRestorePreserveSavedLayout() {
        openEditor()
        replaceGPSWithRPM()
        save()
        openEditor()
        app.buttons["dashboard.restore"].tap()
        XCTAssertTrue(app.buttons["dashboard.restore.confirm"].waitForExistence(timeout: 5))
        tapUniqueHittableButton(app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "取消", "dashboard.cancel")), description: "取消恢复确认")
        assertBefore("controller_rpm", "app_range", page: "dashboard")
        restore()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        cancel()
        relaunch()
        openEditor()
        assertBefore("controller_rpm", "app_range", page: "dashboard")
        cancel()
    }

    func testRestoreAndSaveAppliesCurrentPageDefaultsAfterRelaunch() {
        openEditor()
        replaceGPSWithRPM()
        save()
        openEditor()
        restore()
        save()
        relaunch()
        openEditor()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        // 旧 GPS 回到重点区，不留下第二个同 ID 容器。
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "dashboard.metric.app_gps_speed").count, 1)
        cancel()
    }

    func testMenuReorderPersistsActualOrderAfterRelaunch() {
        openEditor()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        chooseAction("向后移动", metricID: "app_gps_speed")
        assertBefore("app_range", "app_gps_speed", page: "dashboard")
        save()
        relaunch()
        openEditor()
        assertBefore("app_range", "app_gps_speed", page: "dashboard")
        chooseAction("向前移动", metricID: "app_gps_speed")
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        cancel()
        relaunch()
        openEditor()
        assertBefore("app_range", "app_gps_speed", page: "dashboard")
        cancel()
    }

    func testMoveToSourcePromoteHideAndAddDoNotDuplicateMetric() {
        openEditor()
        chooseAction("归还来源分组", metricID: "app_gps_speed")
        assertReturnedGPSInVehicle()
        chooseAction("移至重点参数", metricID: "app_gps_speed")
        chooseAction("隐藏参数", metricID: "app_gps_speed")
        scrollTo(app.buttons["dashboard.add.top"], page: "dashboard")
        app.buttons["dashboard.add.top"].tap()
        let candidate = app.buttons.matching(identifier: "dashboard.candidate.app_gps_speed").firstMatch
        scrollPickerTo(candidate)
        XCTAssertTrue(candidate.isEnabled)
        candidate.tap()
        scrollTo(metric("app_gps_speed"), page: "dashboard")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "dashboard.metric.app_gps_speed").count, 1)
        cancel()
    }

    func testSettingsHasNoLegacyHomeEditorAndAllThreePagesHaveEditingEntry() {
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        for _ in 0..<10 {
            XCTAssertFalse(app.buttons["settings.home"].exists)
            XCTAssertFalse(app.buttons["首页参数"].exists)
            app.swipeUp()
        }
        for page in ["dashboard", "battery", "controller"] {
            openEditor(page)
            XCTAssertFalse(app.navigationBars["首页参数"].exists)
            XCTAssertTrue(app.buttons["\(page).save"].isHittable)
            cancel(page)
        }
    }

    func testThreeTabDraftsSaveAndCancelRemainIndependent() {
        openEditor()
        replaceGPSWithRPM()
        openEditor("battery")
        chooseAction("隐藏参数", metricID: "bms_voltage", page: "battery")
        openEditor("controller")
        chooseAction("隐藏参数", metricID: "controller_voltage", page: "controller")
        save("controller")

        showPage("dashboard")
        XCTAssertTrue(app.buttons["dashboard.cancel"].exists, "切 Tab 必须保留仪表盘草稿")
        assertBefore("controller_rpm", "app_range", page: "dashboard")
        cancel()
        showPage("battery")
        XCTAssertTrue(app.buttons["battery.cancel"].exists)
        scrollTo(metric("bms_current", page: "battery"), page: "battery")
        XCTAssertFalse(metric("bms_voltage", page: "battery").exists)
        cancel("battery")

        relaunch()
        openEditor()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        cancel()
        openEditor("battery")
        scrollTo(metric("bms_voltage", page: "battery"), page: "battery")
        cancel("battery")
        openEditor("controller")
        scrollTo(metric("controller_bus_current", page: "controller"), page: "controller")
        XCTAssertFalse(metric("controller_voltage", page: "controller").exists)
        cancel("controller")
    }

    func testDashboardRestoreDoesNotResetSavedBatteryOrControllerLayouts() {
        openEditor("battery")
        chooseAction("隐藏参数", metricID: "bms_voltage", page: "battery")
        save("battery")
        openEditor("controller")
        chooseAction("隐藏参数", metricID: "controller_voltage", page: "controller")
        save("controller")
        openEditor()
        replaceGPSWithRPM()
        save()
        openEditor()
        restore()
        save()
        relaunch()
        openEditor()
        assertBefore("app_gps_speed", "app_range", page: "dashboard")
        cancel()
        for (page, nextMetric, hiddenMetric) in [
            ("battery", "bms_current", "bms_voltage"),
            ("controller", "controller_bus_current", "controller_voltage")
        ] {
            openEditor(page)
            scrollTo(metric(nextMetric, page: page), page: page)
            XCTAssertFalse(metric(hiddenMetric, page: page).exists, "恢复仪表盘不应重置 \(page)")
            cancel(page)
        }
    }

    func testNativeLongPressDragReordersSameCategoryWithoutDeviceData() {
        openEditor("battery")
        let voltage = metric("bms_voltage", page: "battery")
        let current = metric("bms_current", page: "battery")
        assertBefore("bms_voltage", "bms_current", page: "battery")
        XCTAssertTrue(voltage.staticTexts["--"].exists)
        XCTAssertTrue(current.staticTexts["--"].exists)
        // 真正调用 XCUITest 长按拖放；不以菜单排序或源码标识冒充拖放验证。
        let start = current.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let destination = voltage.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        start.press(forDuration: 1.2, thenDragTo: destination)
        assertBefore("bms_current", "bms_voltage", page: "battery")
        save("battery")
        relaunch()
        openEditor("battery")
        assertBefore("bms_current", "bms_voltage", page: "battery")
        cancel("battery")
    }

    func testControllerFaultWithoutTelemetryStillSupportsHideAndAdd() {
        openEditor("controller")
        let fault = metric("controller_fault", page: "controller")
        scrollTo(fault, page: "controller")
        XCTAssertTrue(fault.staticTexts["--"].exists, "无 BLE 数据不得伪造故障值，也不得阻止布局编辑")
        chooseAction("隐藏参数", metricID: "controller_fault", page: "controller")
        let add = app.buttons["controller.add.controller.state"]
        scrollTo(add, page: "controller")
        add.tap()
        XCTAssertTrue(app.navigationBars["添加参数"].waitForExistence(timeout: 5))
        let candidate = app.buttons.matching(identifier: "controller.candidate.controller_fault").firstMatch
        scrollPickerTo(candidate)
        XCTAssertTrue(candidate.isEnabled)
        candidate.tap()
        scrollTo(fault, page: "controller")
        XCTAssertTrue(fault.staticTexts["--"].exists)
        cancel("controller")
    }

    func testAccessibilityTextLandscapeReachesLastRowAndEditorControlsOnAllPages() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launchIsolatedApp()
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app!)], timeout: 5), .completed)
        for (page, lastMetric, lastSection) in [
            ("dashboard", "controller_fault", "controller"),
            ("battery", "bms_unparsed_bytes", "battery.diagnostics"),
            ("controller", "controller_pending_bytes", "controller.diagnostics")
        ] {
            openEditor(page)
            scrollTo(metric(lastMetric, page: page), page: page, attempts: 80)
            XCTAssertTrue(metric(lastMetric, page: page).isHittable)
            let add = app.buttons["\(page).add.\(lastSection)"]
            scrollTo(add, page: page, attempts: 80)
            XCTAssertTrue(add.isHittable, "最后一行添加入口必须可达：\(page)")
            for action in ["save", "cancel", "restore"] {
                XCTAssertTrue(app.buttons["\(page).\(action)"].isHittable)
            }
            XCTAssertEqual(app.tabBars.buttons.count, 5)
            cancel(page)
        }
    }

    private func metric(_ id: String, page: String = "dashboard") -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "\(page).metric.\(id)").firstMatch
    }

    private func grid(_ page: String) -> XCUIElement {
        app.collectionViews["\(page).parameter-content"]
    }

    private func showPage(_ page: String) {
        guard let title = tabTitles[page] else { XCTFail("未知页面：\(page)"); return }
        app.tabBars.buttons[title].tap()
        XCTAssertTrue(grid(page).waitForExistence(timeout: 5))
    }

    private func openEditor(_ page: String = "dashboard") {
        showPage(page)
        let edit = app.buttons["\(page).edit"]
        scrollTo(edit, page: page)
        edit.tap()
        XCTAssertTrue(app.buttons["\(page).cancel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["首页参数"].exists)
    }

    private func chooseAction(_ title: String, metricID: String, page: String = "dashboard") {
        let actions = grid(page).buttons.matching(identifier: "\(page).actions.\(metricID)").firstMatch
        scrollTo(actions, page: page)
        actions.tap()
        // 原生菜单可能与背后的 sheet/编辑栏具有同名按钮，只选择唯一可点击菜单项。
        tapUniqueHittableButton(app.buttons.matching(NSPredicate(format: "label == %@", title)), description: title)
    }

    private func replaceGPSWithRPM() {
        chooseAction("替换参数", metricID: "app_gps_speed")
        XCTAssertTrue(app.navigationBars["替换参数"].waitForExistence(timeout: 5))
        let candidate = app.buttons.matching(identifier: "dashboard.candidate.controller_rpm").firstMatch
        scrollPickerTo(candidate)
        XCTAssertTrue(candidate.isEnabled)
        candidate.tap()
        XCTAssertTrue(app.buttons["dashboard.save"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["替换参数"].exists)
    }

    private func assertReturnedGPSInVehicle() {
        let gps = metric("app_gps_speed")
        scrollTo(gps, page: "dashboard")
        XCTAssertTrue(gps.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GPS 速度")).firstMatch.exists)
        let addVehicle = app.buttons["dashboard.add.vehicle"]
        scrollTo(addVehicle, page: "dashboard")
        XCTAssertTrue(gps.isHittable, "旧 GPS 应位于车辆区末尾，而不是仍留在顶部或进入控制器区")
        XCTAssertLessThan(gps.frame.minY, addVehicle.frame.minY)
        chooseAction("移至重点参数", metricID: "app_gps_speed")
        // 再归还，确认实际可执行的是底部→顶部→真实来源区，而非复制卡片。
        chooseAction("归还来源分组", metricID: "app_gps_speed")
        scrollTo(addVehicle, page: "dashboard")
        addVehicle.tap()
        XCTAssertTrue(app.navigationBars["添加参数"].waitForExistence(timeout: 5))
        let alreadyPlaced = app.buttons.matching(identifier: "dashboard.candidate.app_gps_speed").firstMatch
        scrollPickerTo(alreadyPlaced)
        XCTAssertFalse(alreadyPlaced.isEnabled)
        app.navigationBars["添加参数"].buttons["取消"].tap()
    }

    private func save(_ page: String = "dashboard") {
        app.buttons["\(page).save"].tap()
        let finished = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished,
                       object: app.buttons["\(page).cancel"])], timeout: 5), .completed)
    }

    private func cancel(_ page: String = "dashboard") {
        app.buttons["\(page).cancel"].tap()
        XCTAssertFalse(app.buttons["\(page).save"].exists)
    }

    private func restore(_ page: String = "dashboard") {
        app.buttons["\(page).restore"].tap()
        let confirm = app.buttons["\(page).restore.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    private func launchIsolatedApp() {
        guard app.launchEnvironment["ANTURIDE_UI_TEST_HOME_SUITE"]?.hasPrefix("UITest-Home-") == true else {
            XCTFail("拒绝启动：套件前缀不在 HomeParameterPrefs 白名单内，会回退到 standard")
            return
        }
        app.launch()
    }

    private func relaunch() {
        app.terminate()
        launchIsolatedApp()
    }

    private func tapUniqueHittableButton(_ query: XCUIElementQuery, description: String) {
        let unique = NSPredicate { _, _ in
            query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count == 1
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: unique, object: app!)],
                            timeout: 5) == .completed else {
            XCTFail("未找到唯一可交互按钮：\(description)")
            return
        }
        let matches = query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        guard matches.count == 1 else { XCTFail("按钮存在歧义：\(description)"); return }
        matches[0].tap()
    }

    private func assertBefore(_ firstID: String, _ secondID: String, page: String) {
        let first = metric(firstID, page: page)
        let second = metric(secondID, page: page)
        scrollTo(first, page: page)
        scrollTo(second, page: page)
        let ordered = NSPredicate { _, _ in
            guard first.exists, second.exists, first.isHittable, second.isHittable else { return false }
            let a = first.frame, b = second.frame
            return a.minY < b.minY - 2 || (abs(a.minY - b.minY) <= 2 && a.minX < b.minX)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ordered, object: app!)], timeout: 5),
                       .completed, "实际卡片顺序应为 \(firstID) → \(secondID)")
    }

    private func scrollTo(_ element: XCUIElement, page: String, attempts: Int = 24) {
        for direction in [true, false] {
            for _ in 0..<attempts {
                if element.exists && element.isHittable { return }
                if direction { grid(page).swipeUp() } else { grid(page).swipeDown() }
            }
        }
        XCTFail("未找到可交互元素：\(element.identifier)")
    }

    private func scrollPickerTo(_ element: XCUIElement) {
        let candidates = NSPredicate(format: "identifier MATCHES %@", "(dashboard|battery|controller)\\.candidate\\..+")
        // 依据动态候选标识定位 List，不猜第一张 collection，也不滚动 sheet 背后的网格。
        let lists = app.collectionViews.containing(candidates).allElementsBoundByIndex
            + app.tables.containing(candidates).allElementsBoundByIndex
        let visibleLists = lists.filter { $0.exists && $0.isHittable }
        guard visibleLists.count == 1, let list = visibleLists.first else {
            XCTFail("候选列表缺失或存在歧义：\(visibleLists.count)")
            return
        }
        for direction in [true, false] {
            for _ in 0..<40 {
                if element.exists && element.isHittable { return }
                if direction { list.swipeUp() } else { list.swipeDown() }
            }
        }
        XCTFail("未找到候选参数：\(element.identifier)")
    }
}
