import XCTest

final class GlacierBMSTests: XCTestCase {
    func testLaunchSmoke() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }
}
