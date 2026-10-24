import ANTuRideDomain
import XCTest
@testable import ANTuRide

/// 图表序列构建的纯函数验证：断点切分、降采样保极值、时序不确定电流孤立点。
final class AccelerationChartSeriesTests: XCTestCase {
    func testSplitsRunsAtReceptionGapsAndKeepsPreDepartureSamples() throws {
        let record = try makeRecord(speeds: still + [
            (2.2, 2), (2.3, 5), (2.4, 10), (2.5, 15), (2.6, 20), (2.8, 22)
        ])
        let output = AccelerationChartSeriesBuilder.build(record: record)
        // 2.6→2.8 的 0.2 s 间隙超过 50 ms 图表阈值（会话 500 ms 限制内），切分为两个连续区间。
        XCTAssertEqual(Set(output.speed.map(\.series)), [0, 1], "间隙两侧必须是不同连线区间")
        XCTAssertEqual(output.speed.map(\.x), output.speed.map(\.x).sorted(), "点按时间升序")
        XCTAssertEqual(output.xMin, -2.1, accuracy: 1e-9, "t0 前的等待/静止样本不裁剪")
        let marks = output.splitMarks
        XCTAssertEqual(marks.map(\.label), ["10 km/h", "20 km/h"])
        XCTAssertEqual(marks.last?.isFinal, true)
        XCTAssertEqual(marks.first?.x ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(marks.last?.x ?? 0, 0.5, accuracy: 1e-9)
    }

    func testDownsampleCapsRunsAndKeepsFirstLastExtremes() throws {
        let total = 3_000
        let currents = (0..<total).map { index -> (Double, Double, Double, Bool) in
            let bus = index == total / 2 ? 99.0 : Double(index % 40)
            return (Double(index) * 0.01, bus, 20, false)
        }
        let record = try makeRecord(speeds: [(0, 0)], currents: currents)
        let output = AccelerationChartSeriesBuilder.build(record: record)
        XCTAssertLessThanOrEqual(output.busCurrent.count, AccelerationChartSeriesBuilder.maxPointsPerRun)
        XCTAssertEqual(output.busCurrent.first?.x ?? -1, 0, accuracy: 1e-9, "保留区间首点")
        XCTAssertEqual(output.busCurrent.last?.x ?? -1, Double(total - 1) * 0.01, accuracy: 1e-9, "保留区间末点")
        XCTAssertTrue(output.busCurrent.contains { $0.y == 99 }, "全局极值点必须保留")
        XCTAssertTrue(output.busCurrent.allSatisfy { $0.series == 0 }, "0.01 s 间距不产生断点")
    }

    func testTimingAmbiguousCurrentsBecomeIsolatedPoints() throws {
        let record = try makeRecord(speeds: [(0, 0), (0.1, 0)],
            currents: [(0, 1, 2, false), (0.1, 3, 4, false), (0.2, 5, 6, true), (0.3, 7, 8, true)])
        let output = AccelerationChartSeriesBuilder.build(record: record)
        XCTAssertEqual(output.busCurrent.count, 2)
        XCTAssertEqual(output.phaseCurrent.count, 2)
        XCTAssertEqual(output.ambiguousPoints.count, 2, "时序不确定电流只画孤立点，不进连线序列")
        XCTAssertTrue(output.ambiguousPoints.allSatisfy { $0.series == -1 })
        XCTAssertEqual(output.xMax, 0.3, accuracy: 1e-9)
    }

    private let still: [(Double, Double)] = (0...21).map { (Double($0) / 10, 0) }

    /// 通过领域会话构造真实记录：速度以 offset 秒注入（时间基准 100 s），系数 1。
    private func makeRecord(speeds: [(Double, Double)],
                            currents: [(Double, Double, Double, Bool)] = []) throws -> AccelerationRecord {
        let session = AccelerationTestSession(config: AccelerationConfig(targetSpeedKmh: 20, rpmKmhPerUnit: 1))
        _ = try session.start(at: 100, date: Date(timeIntervalSince1970: 1_790_000_000), id: "chart-series-tests")
        for sample in speeds {
            session.ingest(AccelerationSpeedSample(source: .rpm, timestamp: 100 + sample.0,
                                                   speedMps: sample.1 / 3.6))
        }
        for current in currents {
            session.ingest(AccelerationCurrentSample(timestamp: 100 + current.0,
                busCurrentA: current.1, phasePeakCurrentA: current.2, rawRpm: 0,
                sequence: 0, timingAmbiguous: current.3))
        }
        let end = 100 + max(speeds.map { $0.0 }.max() ?? 0, currents.map { $0.0 }.max() ?? 0)
        return try XCTUnwrap(session.finish(at: end, reason: "测试结束"))
    }
}
