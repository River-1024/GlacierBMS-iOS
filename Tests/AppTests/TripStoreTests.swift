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
}
