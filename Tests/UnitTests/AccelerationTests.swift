import XCTest
@testable import ANTuRideDomain

final class AccelerationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testDefaultCoefficientAndRPMOnlyContract() throws {
        let config = AccelerationConfig()
        XCTAssertEqual(AccelerationSource.allCases, [.rpm])
        XCTAssertEqual(try XCTUnwrap(config.rpmKmhPerUnit), 0.0782, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(config.rpmSpeedMps(rawRpm: 1000)) * 3.6, 78.2, accuracy: 0.000001)
        XCTAssertNil(config.rpmSpeedMps(rawRpm: .nan))
        var invalid = config
        invalid.rpmKmhPerUnit = 0
        XCTAssertThrowsError(try invalid.validate())
    }

    private func session(target: Double = 25) throws -> AccelerationTestSession {
        let s = AccelerationTestSession(config: AccelerationConfig(targetSpeedKmh: target))
        try s.start(at: 0, date: t0, id: "test")
        return s
    }

    private func sample(_ ms: Double, _ kmh: Double,
                        quality: AccelerationSampleQuality = .valid) -> AccelerationSpeedSample {
        AccelerationSpeedSample(source: .rpm, timestamp: ms / 1000, speedMps: kmh / 3.6, quality: quality)
    }

    private func arm(_ s: AccelerationTestSession) {
        for ms in stride(from: 0.0, through: 2_000, by: 100) { s.ingest(sample(ms, 0)) }
        XCTAssertEqual(s.state(for: .rpm), .ready)
    }

    func testThresholdsInterpolateAndConfirmWithoutAddingConfirmationDelay() throws {
        let s = try session(target: 25)
        arm(s)
        s.ingest(sample(2_100, 0.5)); s.ingest(sample(2_200, 1.0)); s.ingest(sample(2_300, 1.5))
        XCTAssertEqual(s.record?.result(for: .rpm)?.startTimestamp, 2.0, accuracy: 0.000_001)
        for ms in stride(from: 2_400.0, through: 7_000, by: 100) {
            s.ingest(sample(ms, (ms - 2_000) * 0.005))
        }
        s.ingest(sample(7_020, 25))
        let result = try XCTUnwrap(s.record?.result(for: .rpm))
        XCTAssertEqual(result.splits.map(\.targetSpeedKmh), [10, 20, 25])
        XCTAssertEqual(result.splits.map(\.crossedAt), [4, 6, 7], accuracy: 0.000_001)
        XCTAssertEqual(result.splits.map(\.cumulativeSeconds), [2, 4, 5], accuracy: 0.000_001)
        XCTAssertEqual(s.record?.phase, .completed)
    }

    func testCrossingCandidateIsCancelledWhenSpeedFallsBelowTarget() throws {
        let s = try session(target: 10); arm(s)
        s.ingest(sample(2_100, 1)); s.ingest(sample(2_200, 10))
        s.ingest(sample(2_300, 9)); s.ingest(sample(2_400, 10))
        XCTAssertTrue(s.record?.result(for: .rpm)?.splits.isEmpty == true)
        XCTAssertEqual(s.record?.result(for: .rpm)?.state, .running)
    }

    func testLargeGapInvalidatesWithoutInterpolatingAcrossMissingSamples() throws {
        let s = try session(target: 10); arm(s)
        s.ingest(sample(2_100, 1)); s.ingest(sample(2_200, 10)); s.ingest(sample(2_701, 10))
        let result = try XCTUnwrap(s.record?.result(for: .rpm))
        XCTAssertEqual(result.state, .invalid)
        XCTAssertTrue(result.splits.isEmpty)
        XCTAssertTrue(result.reason?.contains("间隙") == true)
    }

    func testTickCanInterruptGapButCannotConfirmMovementOrTarget() throws {
        let s = try session(target: 10); arm(s)
        s.ingest(sample(2_100, 30)); s.tick(at: 2.120)
        XCTAssertEqual(s.state(for: .rpm), .ready)
        s.ingest(sample(2_200, 1)); s.ingest(sample(2_300, 1)); s.tick(at: 2.320)
        XCTAssertEqual(s.record?.result(for: .rpm)?.splits.count, 0)
    }

    func testRecordRoundTripsAsCodable() throws {
        let s = try session(target: 10)
        s.ingest(sample(0, 0)); s.ingest(sample(2_000, 0));
        let record = try XCTUnwrap(s.record)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(AccelerationRecord.self, from: data), record)
    }
}
