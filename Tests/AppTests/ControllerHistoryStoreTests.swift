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

    func testNonFiniteMissingValuesRoundTripAndCSVUses18Columns() throws {
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
        let session = ControllerRecordSession()
        XCTAssertTrue(session.append(saved))
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertEqual(csvText, session.exportControllerCSV())
        XCTAssertTrue(csvText.contains("--V,--A,-1250RPM,--,--,--,3.30V,"))
        XCTAssertFalse(csvText.contains("Infinity"))
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
            for format in ControllerHistoryStore.ExportFormat.allCases {
                XCTAssertThrowsError(try store.export(record, format: format, to: directory))
            }
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
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), ControllerRecordSession.controllerCSVHeader + "\n")
    }

    func testOptionalTimingWarningPersistsAndOldJSONRemainsCompatible() throws {
        let store = ControllerHistoryStore(directory: directory)
        let warning = "重复或倒退的接收时间：已拒绝该采样，未改写时间"
        let record = ControllerHistoryRecord(deviceID: deviceID, deviceName: "controller", startedAt: date,
            endedAt: date.addingTimeInterval(1), samples: [sample(at: date)], timingWarning: warning)
        try store.save(record)
        XCTAssertEqual(try store.load(id: record.id).timingWarning, warning)
        let export = try store.export(record, format: .json, to: directory.appendingPathComponent("exports"))
        let exported = try JSONDecoder().decode(ControllerHistoryRecord.self, from: Data(contentsOf: export))
        XCTAssertEqual(exported.timingWarning, warning)
        let source = directory.appendingPathComponent("\(record.id.uuidString).json")
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        oldJSON.removeValue(forKey: "timingWarning")
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: source)
        let old = try store.load(id: record.id)
        XCTAssertNil(old.timingWarning)
        XCTAssertEqual(old.samples, record.samples)
        XCTAssertNil(makeRecord().timingWarning)
    }

    func testFullTelemetryJSONAndBothTableExportsPreserveSnapshot() throws {
        let store = ControllerHistoryStore(directory: directory)
        let bytes = Data([0xA8, 2, 1, 0x24, 1, 0x1F]) + Data(repeating: 0, count: 31) + Data([0, 0])
        guard case .valid(let telemetry) = MotorControllerProtocol.parseRealtimeResponse(bytes) else {
            return XCTFail("Fixture must decode")
        }
        let sample = ControllerSample(timestamp: date, voltage: 99, current: 99, rpm: 99,
            speed: .nan, throttle: 99, brake: 99, telemetry: telemetry)
        let record = makeRecord(samples: [sample])
        try store.save(record)
        let loaded = try store.load(id: record.id)
        XCTAssertEqual(loaded.samples.first?.telemetry, telemetry)
        let session = ControllerRecordSession()
        XCTAssertTrue(session.append(sample))
        let csv = try store.export(loaded, format: .csv, to: directory.appendingPathComponent("exports"))
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), session.exportControllerCSV())
        let xlsx = try store.export(loaded, format: .xlsx, to: directory.appendingPathComponent("exports"))
        XCTAssertEqual(try Data(contentsOf: xlsx), try session.exportControllerXLSX())
        XCTAssertEqual(try store.load(id: record.id).samples.first?.telemetry, telemetry)
    }

    func testReportingFailuresKeepsCorruptFilesAndHealthyRecords() throws {
        let store = ControllerHistoryStore(directory: directory)
        let record = makeRecord()
        try store.save(record)
        let corruptID = UUID()
        let corrupt = directory.appendingPathComponent("\(corruptID.uuidString).json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: corrupt)
        let report = try store.loadAllReportingFailures()
        XCTAssertEqual(report.records, [record])
        XCTAssertEqual(report.unreadableRecordIDs, [corruptID])
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
    }

    func testSharingUnsavedRecordUsesIndependentSnapshotsAndNeverSavesOrDeletesHistory() throws {
        let store = ControllerHistoryStore(directory: directory)
        let record = makeRecord()
        let exports = directory.appendingPathComponent("exports")
        let first = try store.exportForSharing(record, format: .xlsx, to: exports)
        let bytes = try Data(contentsOf: first)
        let second = try store.exportForSharing(record, format: .xlsx, to: exports)
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        XCTAssertEqual(try store.loadAll(), [])
        try FileManager.default.removeItem(at: first.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        try store.save(record)
        try FileManager.default.removeItem(at: second.deletingLastPathComponent())
        XCTAssertEqual(try store.load(id: record.id), record)
    }

    func testFailedSharingCleansOnlyItsOwnSnapshot() throws {
        let store = ControllerHistoryStore(directory: directory)
        let exports = directory.appendingPathComponent("exports")
        let retained = try store.exportForSharing(makeRecord(), format: .json, to: exports)
        let bytes = try Data(contentsOf: retained)
        let before = try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted()
        let invalid = makeRecord(samples: [sample(at: date.addingTimeInterval(-1))])
        XCTAssertThrowsError(try store.exportForSharing(invalid, format: .xlsx, to: exports))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
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
