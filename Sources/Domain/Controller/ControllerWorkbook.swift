import Foundation

/// Minimal single-sheet OOXML workbook. All cells are inline text, never formulas.
/// Controller timestamp cells contain phone receive time formatted to seconds, not hardware clock precision.
/// ZIP method 0 (stored) needs no compression library; every entry has a CRC32,
/// a local header and a central-directory entry. ZIP64 is deliberately unsupported.
enum ControllerWorkbook {
    enum WorkbookError: LocalizedError {
        case invalidDimensions, cellTooLong, archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidDimensions: return "工作簿行列数量超出 Excel 限制或列数不一致"
            case .cellTooLong: return "工作簿单元格文本超出 Excel 限制"
            case .archiveTooLarge: return "工作簿超出 ZIP32 大小限制"
            }
        }
    }

    static func data(headers: [String], rows: [[String]]) throws -> Data {
        guard !headers.isEmpty, headers.count <= 16_384, rows.count < 1_048_576,
              rows.allSatisfy({ $0.count == headers.count }) else {
            throw WorkbookError.invalidDimensions
        }
        var sheet = declaration + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        sheet += try rowXML(number: 1, values: headers)
        for (index, row) in rows.enumerated() {
            sheet += try rowXML(number: index + 2, values: row)
        }
        sheet += "</sheetData></worksheet>"
        return try storedZIP(entries: [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rootRelationships),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRelationships),
            ("xl/worksheets/sheet1.xml", sheet)
        ])
    }

    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let contentTypes = declaration + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
    """
    private static let rootRelationships = declaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """
    private static let workbook = declaration + """
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="控制器记录" sheetId="1" r:id="rId1"/></sheets></workbook>
    """
    private static let workbookRelationships = declaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
    """

    private static func rowXML(number: Int, values: [String]) throws -> String {
        var xml = "<row r=\"\(number)\">"
        for (index, value) in values.enumerated() {
            guard value.utf16.count <= 32_767 else { throw WorkbookError.cellTooLong }
            xml += "<c r=\"\(columnName(index))\(number)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
            xml += escapedXML(value) + "</t></is></c>"
        }
        return xml + "</row>"
    }

    static func columnName(_ index: Int) -> String {
        precondition(index >= 0)
        var remaining = index + 1
        var name = ""
        repeat {
            remaining -= 1
            name = String(UnicodeScalar(65 + remaining % 26)!) + name
            remaining /= 26
        } while remaining > 0
        return name
    }

    private static func escapedXML(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 38: escaped += "&amp;"
            case 60: escaped += "&lt;"
            case 62: escaped += "&gt;"
            case 34: escaped += "&quot;"
            case 39: escaped += "&apos;"
            case 9, 10: escaped.unicodeScalars.append(scalar)
            // XML parsers normalize raw CR to LF. Preserve the original text.
            case 13: escaped += "&#13;"
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                escaped.unicodeScalars.append(scalar)
            default: break // XML 1.0 forbids the remaining control characters.
            }
        }
        return escaped
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB88320) }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] }
        return crc ^ 0xFFFFFFFF
    }

    private static func storedZIP(entries: [(String, String)]) throws -> Data {
        var archive = Data()
        var central = Data()
        for (path, xml) in entries {
            let name = Data(path.utf8)
            let payload = Data(xml.utf8)
            // Reject ZIP64 sentinel values before integer conversion or writing a file.
            guard name.count <= Int(UInt16.max), payload.count < Int(UInt32.max),
                  archive.count < Int(UInt32.max) else { throw WorkbookError.archiveTooLarge }
            let size = UInt32(payload.count)
            let offset = UInt32(archive.count)
            let crc = crc32(payload)
            archive.appendLE(UInt32(0x04034B50))
            archive.appendLE(UInt16(20)) // version needed: ZIP 2.0
            archive.appendLE(UInt16(0x0800)) // UTF-8 names
            archive.appendLE(UInt16(0)) // stored, not deflate
            archive.appendLE(UInt16(0)) // DOS time 00:00:00
            archive.appendLE(UInt16(0x0021)) // DOS date 1980-01-01
            archive.appendLE(crc)
            archive.appendLE(size)
            archive.appendLE(size)
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0)) // no extra data
            archive.append(name)
            archive.append(payload)

            central.appendLE(UInt32(0x02014B50))
            central.appendLE(UInt16(20)) // made by ZIP 2.0, MS-DOS
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x0021))
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0)) // extra length
            central.appendLE(UInt16(0)) // comment length
            central.appendLE(UInt16(0)) // starting disk
            central.appendLE(UInt16(0)) // internal attributes
            central.appendLE(UInt32(0)) // external attributes
            central.appendLE(offset)
            central.append(name)
        }
        guard entries.count < Int(UInt16.max), central.count < Int(UInt32.max),
              archive.count + central.count + 22 < Int(UInt32.max) else {
            throw WorkbookError.archiveTooLarge
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0)) // disk
        archive.appendLE(UInt16(0)) // central-directory disk
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0)) // comment length
        return archive
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
