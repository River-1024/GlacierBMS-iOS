import XCTest

final class ANTuRideUITests: XCTestCase {
    func testLaunchSmoke() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
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
}
