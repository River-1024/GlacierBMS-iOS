import Foundation
import XCTest
@testable import ANTuRide
import ANTuRideDomain

final class TripStoreTests: XCTestCase {
    private var directory: URL!
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defer { directory = nil }
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testLoadAllFromEmptyDirectoryReturnsEmptyArray() throws {
        XCTAssertEqual(try TripStore(directory: directory).loadAll(), [])
    }

    func testLoadAllFromMissingDirectoryReturnsEmptyArray() throws {
        let missingDirectory = directory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
        XCTAssertEqual(try TripStore(directory: missingDirectory).loadAll(), [])
    }

    func testSaveLoadCodableRoundTripPreservesAllFourSegmentKinds() throws {
        let segments = [
            TripSegment(
                kind: .foreground,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(60),
                distanceMeters: 125.5,
                energyWh: 3.25,
                locationCount: 12,
                energySampleCount: 10,
                invalidLocationCount: 2
            ),
            TripSegment(
                kind: .background,
                startedAt: startedAt.addingTimeInterval(60),
                endedAt: startedAt.addingTimeInterval(120),
                distanceMeters: 240.75,
                energyWh: -1.5,
                locationCount: 18,
                energySampleCount: 15,
                invalidLocationCount: 1
            ),
            TripSegment(
                kind: .suspended,
                startedAt: startedAt.addingTimeInterval(120),
                endedAt: startedAt.addingTimeInterval(150),
                distanceMeters: 0,
                energyWh: 0,
                locationCount: 0,
                energySampleCount: 0,
                invalidLocationCount: 0
            ),
            TripSegment(
                kind: .gap,
                startedAt: startedAt.addingTimeInterval(150),
                endedAt: startedAt.addingTimeInterval(180),
                distanceMeters: 0,
                energyWh: 0,
                locationCount: 0,
                energySampleCount: 0,
                invalidLocationCount: 3
            )
        ]
        let trip = Trip(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(180),
            segments: segments
        )
        // 使用尚不存在的子目录，同时验证 save 会创建持久化目录。
        let tripsDirectory = directory.appendingPathComponent("Trips", isDirectory: true)
        try TripStore(directory: tripsDirectory).save(trip)

        let file = tripsDirectory.appendingPathComponent("\(trip.id.uuidString).json")
        let decoded = try JSONDecoder().decode(Trip.self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded, trip)

        // 重新创建 Store，避免只验证同一实例的内存状态。
        let loaded = try TripStore(directory: tripsDirectory).loadAll()
        XCTAssertEqual(loaded, [trip])
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.segments.map(\.kind), [.foreground, .background, .suspended, .gap])
        XCTAssertEqual(restored.totalDistanceMeters, 366.25, accuracy: 1e-9)
        XCTAssertEqual(restored.totalEnergyWh, 1.75, accuracy: 1e-9)
        XCTAssertEqual(restored.durationSeconds, 180, accuracy: 1e-9)
    }

    func testSaveLoadRoundTripPreservesNilEndedAtAndEmptySegments() throws {
        let trip = Trip(startedAt: startedAt, segments: [])
        try TripStore(directory: directory).save(trip)

        XCTAssertEqual(try TripStore(directory: directory).loadAll(), [trip])
    }

    func testSaveLoadRoundTripPreservesUnfinishedSuspendedCheckpoint() throws {
        let pausedAt = startedAt.addingTimeInterval(60)
        let checkpointAt = startedAt.addingTimeInterval(90)
        let checkpoint = Trip(
            startedAt: startedAt,
            endedAt: nil,
            segments: [
                TripSegment(
                    kind: .foreground,
                    startedAt: startedAt,
                    endedAt: pausedAt,
                    distanceMeters: 125.5,
                    energyWh: 3.25,
                    locationCount: 12,
                    energySampleCount: 10,
                    invalidLocationCount: 2
                ),
                TripSegment(
                    kind: .suspended,
                    startedAt: pausedAt,
                    endedAt: checkpointAt,
                    distanceMeters: 0,
                    energyWh: 0,
                    locationCount: 0,
                    energySampleCount: 0,
                    invalidLocationCount: 0
                )
            ]
        )
        try TripStore(directory: directory).save(checkpoint)

        let loaded = try TripStore(directory: directory).loadAll()
        XCTAssertEqual(loaded, [checkpoint])
        let restored = try XCTUnwrap(loaded.first)
        // 区间快照有结束边界，不代表整次行程已结束。
        XCTAssertNil(restored.endedAt)
        XCTAssertEqual(restored.segments.last?.kind, .suspended)
        XCTAssertEqual(restored.segments.last?.endedAt, checkpointAt)
        XCTAssertEqual(restored.durationSeconds, 90, accuracy: 1e-9)
    }

    func testLoadAllSortsByStartedAtDescending() throws {
        let oldest = Trip(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_000),
            segments: []
        )
        let middle = Trip(startedAt: startedAt.addingTimeInterval(60), segments: [])
        let newest = Trip(startedAt: startedAt.addingTimeInterval(120), segments: [])
        let store = TripStore(directory: directory)
        // 保存顺序与预期排序不同，且最旧行程结束最晚。
        for trip in [middle, newest, oldest] {
            try store.save(trip)
        }

        XCTAssertEqual(try TripStore(directory: directory).loadAll(), [newest, middle, oldest])
    }

    func testLoadAllSkipsCorruptedFilesAndPreservesValidTrips() throws {
        let oldest = Trip(startedAt: startedAt, segments: [])
        let newest = Trip(startedAt: startedAt.addingTimeInterval(60), segments: [])
        let store = TripStore(directory: directory)
        try store.save(oldest)
        try store.save(newest)
        let malformedFile = directory.appendingPathComponent("malformed.json")
        let invalidTripFile = directory.appendingPathComponent("invalid-trip.json")
        try Data("{broken json".utf8).write(to: malformedFile)
        try Data("{}".utf8).write(to: invalidTripFile)

        XCTAssertEqual(try TripStore(directory: directory).loadAll(), [newest, oldest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidTripFile.path))
    }

    func testDeleteRemovesOnlyMatchingTripAndPreservesOtherFiles() throws {
        let deleted = Trip(startedAt: startedAt, segments: [])
        let retained = Trip(startedAt: startedAt.addingTimeInterval(60), segments: [])
        let store = TripStore(directory: directory)
        try store.save(deleted)
        try store.save(retained)
        let deletedFile = directory.appendingPathComponent("\(deleted.id.uuidString).json")
        let retainedFile = directory.appendingPathComponent("\(retained.id.uuidString).json")
        let retainedData = try Data(contentsOf: retainedFile)
        let unrelatedFile = directory.appendingPathComponent("notes.txt")
        let unrelatedData = Data("保留其他文件".utf8)
        try unrelatedData.write(to: unrelatedFile)

        try store.delete(id: deleted.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedFile.path))
        XCTAssertEqual(try TripStore(directory: directory).loadAll(), [retained])
        XCTAssertEqual(try Data(contentsOf: retainedFile), retainedData)
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), unrelatedData)

        // 重复删除及不存在的 ID 不应影响剩余文件。
        try store.delete(id: deleted.id)
        try store.delete(id: UUID())
        XCTAssertEqual(try TripStore(directory: directory).loadAll(), [retained])
        XCTAssertEqual(try Data(contentsOf: retainedFile), retainedData)
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), unrelatedData)
    }
    func testDirectoryReadFailureIsNotReportedAsEmptyHistory() throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: file)
        XCTAssertThrowsError(try TripStore(directory: file).loadAll())
    }

    func testCSVExportsRealSampleFieldsAndPreservesSourceValidity() throws {
        let gps = TripSample(timestamp: startedAt, gpsValid: true,
                             latitude: 31.25, longitude: 121.5, speedMetersPerSecond: 2.5,
                             locationIntervalSeconds: 1, distanceMeters: 2.5)
        let invalid = TripSample(timestamp: startedAt.addingTimeInterval(1), gpsValid: false,
                                 bmsValid: false, speedMetersPerSecond: -1, powerWatts: 50)
        let bms = TripSample(timestamp: startedAt.addingTimeInterval(2), bmsValid: true,
                             powerWatts: -120, voltageVolts: 60, currentAmps: -2,
                             energyIntervalSeconds: 1, energyWh: -0.033)
        let trip = Trip(startedAt: startedAt, segments: [
            segment(.foreground, samples: [gps, invalid]),
            segment(.suspended, samples: []),
            segment(.gap, samples: nil),
            segment(.background, samples: [bms])
        ])
        let url = try TripStore(directory: directory).export(trip, format: .csv, to: exportDirectory)
        let rows = try csvRows(url)
        XCTAssertEqual(rows.count, 4) // 3 个真实输入事件；不生成暂停/缺口样本。
        XCTAssertEqual(rows[0], [
            "trip_id", "trip_started_at", "trip_ended_at", "segment_index", "segment_kind",
            "segment_started_at", "segment_ended_at", "sample_index", "timestamp",
            "gps_valid", "bms_valid", "latitude", "longitude", "speed_meters_per_second",
            "voltage_volts", "current_amps", "power_watts", "location_interval_seconds",
            "distance_meters", "energy_interval_seconds", "energy_wh"
        ])
        for row in rows { XCTAssertEqual(row.count, 21) }
        XCTAssertEqual(rows[1][0], trip.id.uuidString)
        XCTAssertEqual(rows[1][1], "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(rows[1][2], "") // 未结束的检查点不伪造结束时间。
        XCTAssertEqual(Array(rows[1][3...8]), ["1", "foreground", "2023-11-14T22:13:20.000Z",
                                              "2023-11-14T22:13:30.000Z", "1", "2023-11-14T22:13:20.000Z"])
        XCTAssertEqual(Array(rows[1][9...20]), ["true", "", "31.25", "121.5", "2.5",
                                               "", "", "", "1.0", "2.5", "", ""])
        XCTAssertEqual(rows[2][7], "2")
        XCTAssertEqual(Array(rows[2][9...13]), ["false", "false", "", "", "-1.0"])
        XCTAssertEqual(rows[2][16], "50.0") // 无效值保留原数值并由有效性标记，非插值。
        XCTAssertEqual(rows[3][3], "4") // 原始区间索引，保留中间暂停/缺口。
        XCTAssertEqual(rows[3][4], "background")
        XCTAssertEqual(rows[3][7], "1")
        XCTAssertEqual(rows[3][8], "2023-11-14T22:13:22.000Z")
        XCTAssertEqual(Array(rows[3][9...20]), ["", "true", "", "", "", "60.0", "-2.0",
                                               "-120.0", "", "", "1.0", "-0.033"])
    }

    func testCSVLeavesNonFiniteAndMissingValuesBlankButPreservesZero() throws {
        let sample = TripSample(timestamp: startedAt, gpsValid: false, bmsValid: true,
                                latitude: .nan, longitude: .infinity, speedMetersPerSecond: -.infinity,
                                powerWatts: 0, voltageVolts: 0, currentAmps: 0,
                                locationIntervalSeconds: .nan, distanceMeters: 0,
                                energyIntervalSeconds: 0, energyWh: 0)
        let trip = Trip(startedAt: startedAt, segments: [segment(.foreground, samples: [sample])])
        let url = try TripStore(directory: directory).export(trip, format: .csv, to: exportDirectory)
        let row = try csvRows(url)[1]
        XCTAssertEqual(Array(row[9...20]), ["false", "true", "", "", "", "0.0", "0.0", "0.0",
                                          "", "0.0", "0.0", "0.0"])
    }

    func testCSVCorrectlyEscapesCommaQuoteCRLFAndUnicode() {
        XCTAssertEqual(TripStore.csvRow(["普通", "a,b", "say \"hi\"", "line1\r\nline2", "", "\r", "\n"]),
                       "普通,\"a,b\",\"say \"\"hi\"\"\",\"line1\r\nline2\",,\"\r\",\"\n\"\r\n")
    }

    func testCSVLegacyAndEmptyTripsHaveOnlyHeaderWithoutFabricatedSamples() throws {
        let trips = [Trip(startedAt: startedAt, segments: []),
                     Trip(startedAt: startedAt, segments: [segment(.foreground, samples: nil)]),
                     Trip(startedAt: startedAt, segments: [segment(.gap, samples: [])])]
        for trip in trips {
            let url = try TripStore(directory: directory).export(trip, format: .csv, to: exportDirectory)
            XCTAssertEqual(try csvRows(url).count, 1)
        }
    }

    func testJSONExportRoundTripsLegacyAndSampledCheckpointWithoutSaving() throws {
        // 模拟原始保存路径不可用；导出不必依赖原始 save 的成功。
        let blocked = directory.appendingPathComponent("blocked-store")
        try Data("file".utf8).write(to: blocked)
        let store = TripStore(directory: blocked)
        let sample = TripSample(timestamp: startedAt, gpsValid: true, speedMetersPerSecond: 0)
        let trips = [Trip(startedAt: startedAt, segments: [segment(.foreground, samples: nil)]),
                     Trip(startedAt: startedAt, segments: [segment(.background, samples: [sample])])]
        for trip in trips {
            XCTAssertThrowsError(try store.save(trip))
            let url = try store.export(trip, format: .json, to: exportDirectory)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(try JSONDecoder().decode(Trip.self, from: data), trip)
            XCTAssertTrue(url.lastPathComponent.hasPrefix("trip-\(trip.id.uuidString)-"))
            XCTAssertEqual(url.pathExtension, "json")
            XCTAssertNil(trip.endedAt)
            let csv = try store.export(trip, format: .csv, to: exportDirectory)
            XCTAssertEqual(try csvRows(csv).count, (trip.segments[0].samples?.count ?? 0) + 1)
        }
    }

    func testExportsAreIndependentPersistentSnapshotsAndSurviveTripDeletion() throws {
        let store = TripStore(directory: directory.appendingPathComponent("Trips", isDirectory: true))
        let trip = Trip(startedAt: startedAt, segments: [
            segment(.foreground, samples: [TripSample(timestamp: startedAt, bmsValid: true, powerWatts: 0)])
        ])
        try store.save(trip)
        var originals: [(URL, Data)] = []
        for format in [TripStore.ExportFormat.json, .csv] {
            let url = try store.export(trip, format: format, to: exportDirectory)
            originals.append((url, try Data(contentsOf: url)))
            let changed = Trip(id: trip.id, startedAt: startedAt, endedAt: startedAt, segments: [])
            let repeated = try store.export(changed, format: format, to: exportDirectory)
            XCTAssertNotEqual(url, repeated)
            XCTAssertEqual(url.deletingLastPathComponent(), exportDirectory)
        }
        try store.delete(id: trip.id)
        XCTAssertEqual(try store.loadAll(), [])
        for (url, data) in originals {
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).count, 4)
    }

    func testDefaultExportDestinationIsDocumentsExportsForBothFormats() throws {
        let expected = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        let trip = Trip(startedAt: startedAt, segments: [])
        var files: [URL] = []
        defer {
            // 只移除本测试拥有的文件，不清理共享 Documents/Exports 目录。
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        for format in [TripStore.ExportFormat.json, .csv] {
            let url = try TripStore(directory: directory).export(trip, format: format)
            files.append(url)
            XCTAssertEqual(url.deletingLastPathComponent(), expected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testExportFailurePreservesOriginalTripAndPreviousExport() throws {
        let trip = Trip(startedAt: startedAt, segments: [])
        let store = TripStore(directory: directory)
        try store.save(trip)
        let previous = try store.export(trip, format: .json, to: exportDirectory)
        let previousData = try Data(contentsOf: previous)
        let blocked = directory.appendingPathComponent("blocked-export")
        try Data("file".utf8).write(to: blocked)
        for format in [TripStore.ExportFormat.json, .csv] {
            XCTAssertThrowsError(try store.export(trip, format: format, to: blocked))
        }
        XCTAssertEqual(try store.loadAll(), [trip])
        XCTAssertEqual(try Data(contentsOf: previous), previousData)
    }

    func testCSVExportsEverySampleNotOnlyFirstBrowserPage() throws {
        let samples = (0..<251).map { index in
            TripSample(timestamp: startedAt.addingTimeInterval(Double(index)), bmsValid: true,
                       powerWatts: Double(index))
        }
        let trip = Trip(startedAt: startedAt, segments: [segment(.foreground, samples: samples)])
        let url = try TripStore(directory: directory).export(trip, format: .csv, to: exportDirectory)
        let rows = try csvRows(url)
        XCTAssertEqual(rows.count, 252)
        XCTAssertEqual(rows.last?[7], "251")
        XCTAssertEqual(rows.last?[16], "250.0")
    }

    func testPaginationBoundariesAndClamping() {
        XCTAssertEqual(TripStore.pageRange(count: 0, page: 0), 0..<0)
        XCTAssertEqual(TripStore.pageRange(count: 100, page: 0), 0..<100)
        XCTAssertEqual(TripStore.pageRange(count: 101, page: 1), 100..<101)
        XCTAssertEqual(TripStore.pageRange(count: 201, page: 0), 0..<100)
        XCTAssertEqual(TripStore.pageRange(count: 201, page: 1), 100..<200)
        XCTAssertEqual(TripStore.pageRange(count: 201, page: 2), 200..<201)
        XCTAssertEqual(TripStore.pageRange(count: 201, page: Int.max), 200..<201)
        XCTAssertEqual(TripStore.pageRange(count: 201, page: Int.min), 0..<100)
        XCTAssertEqual(TripStore.pageRange(count: 0, page: 100), 0..<0)
        XCTAssertEqual(TripStore.pageRange(count: 3, page: 2, pageSize: 1), 2..<3)
        XCTAssertEqual(TripStore.pageRange(count: 21, page: 1, pageSize: 20), 20..<21)
        XCTAssertEqual(TripStore.pageRange(count: 3, page: 1, pageSize: 0), 1..<2)
        XCTAssertEqual(TripStore.pageRange(count: Int.max, page: Int.max, pageSize: Int.max), 0..<Int.max)
        let last = TripStore.pageRange(count: Int.max, page: Int.max)
        XCTAssertEqual(last.upperBound, Int.max)
        XCTAssertLessThanOrEqual(last.count, 100)
    }

    func testSamplePagesAreBoundedAndKeepOriginalOrderWithoutDuplicates() {
        let samples = (0..<10_001).map { index in
            TripSample(timestamp: startedAt.addingTimeInterval(Double(index)), gpsValid: index % 2 == 0,
                       speedMetersPerSecond: Double(index))
        }
        var visited: [TripSample] = []
        for page in 0...100 {
            let range = TripStore.pageRange(count: samples.count, page: page)
            XCTAssertLessThanOrEqual(range.count, 100)
            visited.append(contentsOf: samples[range])
        }
        XCTAssertEqual(visited, samples)
        XCTAssertEqual(Array(samples[TripStore.pageRange(count: samples.count, page: 100)]), [samples.last!])
        let legacy = segment(.foreground, samples: nil)
        XCTAssertTrue(TripStore.pageRange(count: legacy.samples?.count ?? 0, page: 2).isEmpty)
    }

    private var exportDirectory: URL {
        directory.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    private func segment(_ kind: TripSegmentKind, samples: [TripSample]?) -> TripSegment {
        TripSegment(kind: kind, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(10),
                    distanceMeters: 125, energyWh: -1, locationCount: 2, energySampleCount: 1,
                    invalidLocationCount: 1, samples: samples)
    }

    /// 本 schema 的字段本身不含逗号；单元格转义另由 csvRow 的专项回归验证。
    private func csvRows(_ url: URL) throws -> [[String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\r\n"))
        return text.components(separatedBy: "\r\n").dropLast().map {
            $0.components(separatedBy: ",")
        }
    }
}
