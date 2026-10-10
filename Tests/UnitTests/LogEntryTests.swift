import XCTest
@testable import ANTuRide

final class LogEntryTests: XCTestCase {
    func testSerializeParseRoundTrip() {
        let entry = LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: .notice,
            category: "ble",
            message: "已连接外设 ANTBMS",
            file: "BmsBluetoothService.swift",
            function: "didConnect",
            line: 215
        )
        let line = entry.serialized()
        let parsed = LogEntry.parse(line: line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.level, .notice)
        XCTAssertEqual(parsed?.category, "ble")
        XCTAssertEqual(parsed?.message, "已连接外设 ANTBMS")
    }

    func testNewlinesAreEscapedToOneLine() {
        let entry = LogEntry(timestamp: Date(), level: .debug, category: "x", message: "第一行\n第二行")
        let line = entry.serialized()
        XCTAssertFalse(line.contains("\n"), "序列化结果必须为单行")
        XCTAssertEqual(LogEntry.parse(line: line)?.message, "第一行\n第二行")
    }

    func testMessageContainingSeparatorSurvives() {
        // 十六进制转储或文本里可能含 " | "，解析需保留完整消息。
        let entry = LogEntry(timestamp: Date(), level: .info, category: "protocol", message: "7E A1 | 11 00")
        let line = entry.serialized()
        XCTAssertEqual(LogEntry.parse(line: line)?.message, "7E A1 | 11 00")
    }

    func testMalformedLineReturnsNil() {
        XCTAssertNil(LogEntry.parse(line: "这不是一条合法日志"))
        XCTAssertNil(LogEntry.parse(line: "2026-10-10 10:00:00.000 | NOTALEVEL | ble | msg"))
    }

    func testExportedTextContainsAllParts() {
        let entry = LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            level: .error,
            category: "protocol",
            message: "解析返回 nil",
            file: "AntProtocol.swift",
            function: "parse",
            line: 42
        )
        let text = entry.exportedText()
        XCTAssertTrue(text.contains("ERROR"))
        XCTAssertTrue(text.contains("protocol"))
        XCTAssertTrue(text.contains("解析返回 nil"))
        XCTAssertTrue(text.contains("AntProtocol.swift:42"))
    }
}
