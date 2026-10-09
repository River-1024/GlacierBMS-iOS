import XCTest

final class ANTuRideUITests: XCTestCase {
    func testLaunchSmoke() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }
}
