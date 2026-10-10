import ANTuRideDomain
import Foundation
import XCTest
@testable import ANTuRide

final class ControllerHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private let date = Date(timeIntervalSince1970: 1_700_000_000.125)
    private let deviceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ControllerHistoryStoreTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testJSONRoundTripKeepsMetadataOrderAndFractionalDates() throws {
        let store = ControllerHistoryStore(directory: directory)
        let record = makeRecord()
        try store.save(record)
        XCTAssertEqual(try store.load(id: record.id), record)
        XCTAssertEqual(try ControllerHistoryStore(directory: directory).loadAll(), [record])
        let json = try Data(contentsOf: directory.appendingPathComponent("\(record.id.uuidString).json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["deviceName"] as? String, "控制器,\"中文\"/../")
    }

    func testNonFiniteMissingValuesRoundTripAndCSVUsesEmptyCells() throws {
        let store = ControllerHistoryStore(directory: directory)
        let sample = ControllerSample(timestamp: date, voltage: .nan, current: .infinity,
                                      rpm: -1250, speed: -.infinity, throttle: 3.3, brake: .nan)
        let record = makeRecord(samples: [sample])
        try store.save(record)
        let loaded = try store.load(id: record.id)
        let saved = try XCTUnwrap(loaded.samples.first)
        XCTAssertTrue(saved.voltage.isNaN)
        XCTAssertEqual(saved.current, .infinity)
        XCTAssertEqual(saved.speed, -.infinity)
        XCTAssertTrue(saved.brake.isNaN)
        let csv = try store.export(loaded, format: .csv, to: directory.appendingPathComponent("exports"))
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), ControllerRecordSession.csvHeader + "\n" +
                       "2023-11-14T22:13:20.125Z,,,-1250,,3.3,\n")
        let json = try store.export(loaded, format: .json, to: directory.appendingPathComponent("exports"))
        XCTAssertTrue(try String(contentsOf: json, encoding: .utf8).contains("\"NaN\""))
    }

    func testExportsAreIndependentFilesAndDoNotOverwritePersistentSource() throws {
        let store = ControllerHistoryStore(directory: directory)
        let record = makeRecord()
        try store.save(record)
        let source = directory.appendingPathComponent("\(record.id.uuidString).json")
        let bytes = try Data(contentsOf: source)
        let exports = directory.appendingPathComponent("exports")
        for format in ControllerHistoryStore.ExportFormat.allCases {
            let url = try store.export(record, format: format, to: exports)
            XCTAssertEqual(url.lastPathComponent, "controller-\(record.id.uuidString).\(format.rawValue)")
            XCTAssertFalse(try Data(contentsOf: url).isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try store.loadAll(), [record])
    }

    func testMissingDirectoryIsEmptyButFileAsDirectoryThrows() throws {
        let absent = directory.appendingPathComponent("missing")
        XCTAssertEqual(try ControllerHistoryStore(directory: absent).loadAll(), [])
        let file = directory.appendingPathComponent("not-directory")
        try Data("preserve".utf8).write(to: file)
        let store = ControllerHistoryStore(directory: file)
        XCTAssertThrowsError(try store.loadAll())
        XCTAssertThrowsError(try store.save(makeRecord()))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserve")
    }

    func testLoadSortsNewestFirstAndSkipsButPreservesCorruptOrMismatchedFiles() throws {
        let store = ControllerHistoryStore(directory: directory)
        let oldest = makeRecord()
        let newest = ControllerHistoryRecord(deviceID: deviceID, deviceName: "new", startedAt: date.addingTimeInterval(10),
                                             endedAt: date.addingTimeInterval(11), samples: [])
        try store.save(newest)
        try store.save(oldest)
        let corrupt = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{broken".utf8).write(to: corrupt)
        let wrongID = UUID()
        let mismatch = directory.appendingPathComponent("\(wrongID.uuidString).json")
        try Data(contentsOf: directory.appendingPathComponent("\(oldest.id.uuidString).json")).write(to: mismatch)
        XCTAssertThrowsError(try store.load(id: wrongID))
        XCTAssertEqual(try store.loadAll(), [newest, oldest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatch.path))
    }

    func testDeleteIsIDScopedIdempotentAndKeepsOtherRecordsAndExports() throws {
        let store = ControllerHistoryStore(directory: directory)
        let first = makeRecord()
        let retained = makeRecord()
        try store.save(first)
        try store.save(retained)
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        let export = try store.export(first, format: .csv, to: directory)
        let retainedBytes = try Data(contentsOf: directory.appendingPathComponent("\(retained.id.uuidString).json"))
        try store.delete(id: first.id)
        try store.delete(id: first.id)
        try store.delete(id: UUID())
        XCTAssertEqual(try store.loadAll(), [retained])
        XCTAssertThrowsError(try store.load(id: first.id))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("\(retained.id.uuidString).json")), retainedBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    }

    func testRejectsDuplicateDescendingAndOutsideSessionSamplesBeforeWriting() throws {
        let store = ControllerHistoryStore(directory: directory)
        let first = sample(at: date)
        for samples in [[first, first], [sample(at: date.addingTimeInterval(1)), first],
                        [sample(at: date.addingTimeInterval(-1))], [sample(at: date.addingTimeInterval(3))],
                        [sample(at: Date(timeIntervalSince1970: .nan))]] {
            let record = makeRecord(samples: samples)
            XCTAssertThrowsError(try store.save(record))
            XCTAssertThrowsError(try store.export(record, format: .csv, to: directory))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRejectsInvalidMetadataAndSupportsEmptySessions() throws {
        let store = ControllerHistoryStore(directory: directory)
        for endedAt in [date.addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity),
                        Date(timeIntervalSince1970: 253_402_300_800)] {
            let record = ControllerHistoryRecord(deviceID: deviceID, deviceName: "bad", startedAt: date, endedAt: endedAt, samples: [])
            XCTAssertThrowsError(try store.save(record))
        }
        let empty = makeRecord(samples: [])
        try store.save(empty)
        let csv = try store.export(empty, format: .csv, to: directory)
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), ControllerRecordSession.csvHeader + "\n")
    }

    private func makeRecord(samples: [ControllerSample]? = nil) -> ControllerHistoryRecord {
        ControllerHistoryRecord(deviceID: deviceID, deviceName: "控制器,\"中文\"/../", startedAt: date,
                                endedAt: date.addingTimeInterval(2), samples: samples ?? [sample(at: date), sample(at: date.addingTimeInterval(1))])
    }

    private func sample(at timestamp: Date) -> ControllerSample {
        ControllerSample(timestamp: timestamp, voltage: 72.3, current: -12.5, rpm: 1250,
                         speed: 31.25, throttle: 3.3, brake: 0.4)
    }
}
