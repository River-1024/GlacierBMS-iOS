import XCTest
@testable import ANTuRide

final class LogLevelTests: XCTestCase {
    func testComparableOrdering() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.notice)
        XCTAssertTrue(LogLevel.notice < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertTrue(LogLevel.error < LogLevel.fault)
    }

    func testThresholdFiltering() {
        // 模拟「最低记录等级 = notice」时的取舍。
        let threshold = LogLevel.notice
        let recorded = LogLevel.allCases.filter { $0 >= threshold }
        XCTAssertEqual(recorded, [.notice, .warning, .error, .fault])
    }

    func testTagRoundTrip() {
        for level in LogLevel.allCases {
            XCTAssertEqual(LogLevel.parse(level.tag), level, "等级 \(level) 标签无法往返解析")
        }
    }

    func testParseAliases() {
        // 兼容 WARNING/CRITICAL 等别名写法。
        XCTAssertEqual(LogLevel.parse("WARN"), .warning)
        XCTAssertEqual(LogLevel.parse("WARNING"), .warning)
        XCTAssertEqual(LogLevel.parse("CRITICAL"), .fault)
        XCTAssertEqual(LogLevel.parse("DEFAULT"), .notice)
        XCTAssertNil(LogLevel.parse("UNKNOWN"))
    }

    func testAllCasesCount() {
        // 注意：方法名不可用 testCaseCount —— 会与 XCTestCase 的同名属性冲突。
        XCTAssertEqual(LogLevel.allCases.count, 6)
    }
}
