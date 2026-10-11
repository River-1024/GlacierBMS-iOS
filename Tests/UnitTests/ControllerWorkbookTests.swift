import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import ANTuRideDomain

final class ControllerWorkbookTests: XCTestCase {
    func testCRC32GoldenVectors() {
        XCTAssertEqual(ControllerWorkbook.crc32(Data()), 0)
        XCTAssertEqual(ControllerWorkbook.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(ControllerWorkbook.crc32(Data([0, 1, 2, 3, 255])), 0x7B35F858)
    }

    func testStoredZIPHasValidCRCsLocalHeadersCentralDirectoryAndOOXMLRelationships() throws {
        let data = try ControllerWorkbook.data(headers: ControllerRecordColumns.headers, rows: [])
        let entries = try unzipStored(data)
        XCTAssertEqual(Set(entries.keys), Set([
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"
        ]))
        for xml in entries.values { XCTAssertNotNil(try parseXML(xml)) }
        let contentTypes = String(decoding: try XCTUnwrap(entries["[Content_Types].xml"]), as: UTF8.self)
        XCTAssertTrue(contentTypes.contains("PartName=\"/xl/workbook.xml\""))
        XCTAssertTrue(contentTypes.contains("PartName=\"/xl/worksheets/sheet1.xml\""))
        XCTAssertTrue(String(decoding: try XCTUnwrap(entries["_rels/.rels"]), as: UTF8.self)
            .contains("Target=\"xl/workbook.xml\""))
        XCTAssertTrue(String(decoding: try XCTUnwrap(entries["xl/_rels/workbook.xml.rels"]), as: UTF8.self)
            .contains("Target=\"worksheets/sheet1.xml\""))
        let sheet = try parseXML(XCTUnwrap(entries["xl/worksheets/sheet1.xml"]))
        XCTAssertEqual(sheet.rows, [ControllerRecordColumns.headers])
        XCTAssertEqual(sheet.cellReferences.first, "A1")
        XCTAssertEqual(sheet.cellReferences.last, "R1")
        XCTAssertEqual(sheet.cellTypes, Array(repeating: "inlineStr", count: 18))
        XCTAssertFalse(sheet.hasFormula)
        XCTAssertEqual(data, try ControllerWorkbook.data(headers: ControllerRecordColumns.headers, rows: []))
    }

    func testUnicodeEscapingWhitespaceInvalidControlsAndFormulaLikeText() throws {
        let values = ["控制器 🚲", "<&>\"'", "=HYPERLINK(\"evil\")", " leading \t\n\r trailing ", "A\u{0}\u{1}\u{FFFE}\u{FFFF}B"]
        let data = try ControllerWorkbook.data(headers: ["A", "B", "C", "D", "E"], rows: [values])
        let sheet = try parseXML(XCTUnwrap(unzipStored(data)["xl/worksheets/sheet1.xml"]))
        XCTAssertEqual(sheet.rows[1], Array(values.prefix(4)) + ["AB"])
        XCTAssertFalse(sheet.hasFormula)
        XCTAssertEqual(sheet.cellTypes, Array(repeating: "inlineStr", count: 10))
    }

    func testSessionWorkbookContains18ColumnsNewestFirstAndNoFabricatedSpeed() throws {
        let session = ControllerRecordSession()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<2 {
            XCTAssertTrue(session.append(ControllerSample(timestamp: start.addingTimeInterval(Double(index)),
                voltage: 72, current: -1, rpm: 100 + index, speed: 999, throttle: 3.3, brake: .nan)))
        }
        let zone = TimeZone(secondsFromGMT: 0)!
        let data = try session.exportControllerXLSX(timeZone: zone)
        let sheet = try parseXML(XCTUnwrap(unzipStored(data)["xl/worksheets/sheet1.xml"]))
        XCTAssertEqual(sheet.rows.count, 3)
        XCTAssertEqual(sheet.rows[0], ControllerRecordColumns.headers)
        XCTAssertEqual(sheet.rows[1], ControllerRecordColumns.row(for: session.samples[1], timeZone: zone))
        XCTAssertEqual(sheet.rows[2], ControllerRecordColumns.row(for: session.samples[0], timeZone: zone))
        XCTAssertEqual(sheet.rows[1][2], "101RPM")
        XCTAssertFalse(sheet.rows.flatMap { $0 }.contains("999"))
        XCTAssertEqual(session.count, 2)
        XCTAssertFalse(session.isFinished)
    }

    func testSubsecondReceiveTimesAreNotFakedToMakeSpreadsheetTimestampsUnique() throws {
        let session = ControllerRecordSession()
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        for date in [start, start.addingTimeInterval(0.05)] {
            XCTAssertTrue(session.append(ControllerSample(timestamp: date, voltage: 72, current: 0,
                rpm: 100, speed: .nan, throttle: 3.3, brake: .nan)))
        }
        let zone = TimeZone(secondsFromGMT: 0)!
        let data = try session.exportControllerXLSX(timeZone: zone)
        let sheet = try parseXML(XCTUnwrap(unzipStored(data)["xl/worksheets/sheet1.xml"]))
        XCTAssertEqual(sheet.rows[1][17], "2023-11-14 22:13:20")
        XCTAssertEqual(sheet.rows[2][17], sheet.rows[1][17])
        XCTAssertEqual(session.samples.map(\.timestamp), [start, start.addingTimeInterval(0.05)])
    }

    func testColumnNamesAndExcelLimitsFailExplicitly() throws {
        for (index, name) in [(0, "A"), (17, "R"), (25, "Z"), (26, "AA"), (16_383, "XFD")] {
            XCTAssertEqual(ControllerWorkbook.columnName(index), name)
        }
        XCTAssertThrowsError(try ControllerWorkbook.data(headers: [], rows: []))
        XCTAssertThrowsError(try ControllerWorkbook.data(headers: ["A"], rows: [["A", "B"]]))
        XCTAssertThrowsError(try ControllerWorkbook.data(headers: Array(repeating: "A", count: 16_385), rows: []))
        XCTAssertThrowsError(try ControllerWorkbook.data(headers: ["A"], rows: [[String(repeating: "a", count: 32_768)]]))
        XCTAssertThrowsError(try ControllerWorkbook.data(headers: ["A"], rows: [[String(repeating: "🚲", count: 16_384)]]))
    }

    func testZIPReaderRejectsPayloadCorruption() throws {
        var data = try ControllerWorkbook.data(headers: ["A"], rows: [])
        // First payload follows the 30-byte local header and UTF-8 path.
        data[30 + "[Content_Types].xml".utf8.count] ^= 1
        XCTAssertThrowsError(try unzipStored(data))
    }

    /// Independent small stored-ZIP reader: checks central entries against local headers,
    /// calculates CRC bit-by-bit (not using the writer's table), then exposes actual payloads.
    private func unzipStored(_ data: Data) throws -> [String: Data] {
        func integer(_ offset: Int, _ length: Int) throws -> UInt32 {
            guard offset >= 0, offset + length <= data.count else { throw invalidZIP() }
            return (0..<length).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        }
        func require(_ condition: Bool) throws { if !condition { throw invalidZIP() } }
        let end = data.count - 22
        try require(try integer(end, 4) == 0x06054B50)
        try require(try integer(end + 4, 2) == 0 && integer(end + 6, 2) == 0)
        try require(try integer(end + 20, 2) == 0)
        let count = Int(try integer(end + 10, 2))
        try require(try integer(end + 8, 2) == UInt32(count))
        let centralSize = Int(try integer(end + 12, 4))
        let centralStart = Int(try integer(end + 16, 4))
        try require(centralStart + centralSize == end)
        var cursor = centralStart
        var localEnd = 0
        var entries: [String: Data] = [:]
        for _ in 0..<count {
            try require(try integer(cursor, 4) == 0x02014B50)
            try require(try integer(cursor + 8, 2) == 0x0800)
            try require(try integer(cursor + 10, 2) == 0)
            let crc = try integer(cursor + 16, 4)
            let size = Int(try integer(cursor + 24, 4))
            try require(try integer(cursor + 20, 4) == UInt32(size))
            let nameLength = Int(try integer(cursor + 28, 2))
            try require(try integer(cursor + 30, 2) == 0 && integer(cursor + 32, 2) == 0)
            let offset = Int(try integer(cursor + 42, 4))
            try require(offset == localEnd)
            try require(cursor + 46 + nameLength <= end)
            let nameBytes = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let name = try XCTUnwrap(String(data: nameBytes, encoding: .utf8))
            try require(try integer(offset, 4) == 0x04034B50)
            try require(try integer(offset + 6, 2) == 0x0800 && integer(offset + 8, 2) == 0)
            try require(try integer(offset + 14, 4) == crc)
            try require(try integer(offset + 18, 4) == UInt32(size) && integer(offset + 22, 4) == UInt32(size))
            try require(try integer(offset + 26, 2) == UInt32(nameLength) && integer(offset + 28, 2) == 0)
            let payloadStart = offset + 30 + nameLength
            try require(payloadStart + size <= centralStart)
            try require(data.subdata(in: offset + 30..<payloadStart) == nameBytes)
            let payload = data.subdata(in: payloadStart..<payloadStart + size)
            var expected: UInt32 = 0xFFFFFFFF
            for byte in payload {
                expected ^= UInt32(byte)
                for _ in 0..<8 { expected = (expected >> 1) ^ (expected & 1 == 0 ? 0 : 0xEDB88320) }
            }
            try require((expected ^ 0xFFFFFFFF) == crc && entries[name] == nil)
            entries[name] = payload
            localEnd = payloadStart + size
            cursor += 46 + nameLength
        }
        try require(cursor == end && localEnd == centralStart)
        return entries
    }

    private func invalidZIP() -> NSError { NSError(domain: "ControllerWorkbookTests.ZIP", code: 1) }

    private func parseXML(_ data: Data) throws -> SheetXMLReader {
        let reader = SheetXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw parser.parserError ?? invalidZIP() }
        return reader
    }
}

private final class SheetXMLReader: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    var cellReferences: [String] = []
    var cellTypes: [String] = []
    var hasFormula = false
    private var inText = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row": rows.append([])
        case "c":
            cellReferences.append(attributeDict["r"] ?? "")
            cellTypes.append(attributeDict["t"] ?? "")
        case "t": text = ""; inText = true
        case "f": hasFormula = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            if !rows.isEmpty { rows[rows.count - 1].append(text) }
            inText = false
        }
    }
}
