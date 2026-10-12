import Foundation
import XCTest
@testable import ANTuRideDomain

final class RangeDrivingWindowTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func span(_ start: Double, _ end: Double, _ p0: Double = 1_800,
                      _ p1: Double = 1_800, _ i0: Double = 18, _ i1: Double = 18)
        -> RangeElectricalSpan {
        RangeElectricalSpan(startedAt: date(start), endedAt: date(end),
                            startPowerW: p0, endPowerW: p1,
                            startCurrentA: i0, endCurrentA: i1)
    }

    private func interval(_ start: Double = 0, _ end: Double = 10,
                          distance: Double = 100, power: Double = 1_800,
                          spans: [RangeElectricalSpan]? = nil) -> RangeDrivingInterval {
        RangeDrivingInterval(startedAt: date(start), endedAt: date(end),
                             distanceMeters: distance,
                             electricalSpans: spans ?? [span(start, end, power, power)])
    }

    private func window(distance: Double = 200, power: Double = 600,
                        lastDuration: Double = 10) -> RangeDrivingWindow {
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(0, 10, distance: distance / 3, power: power)))
        XCTAssertTrue(result.append(interval(10, 20, distance: distance / 3, power: power)))
        XCTAssertTrue(result.append(interval(20, 20 + lastDuration,
                                             distance: distance / 3, power: power)))
        return result
    }

    func testLinearElectricalIntegrationAndCodableRoundTrip() throws {
        let value = span(0, 10, 360, 1_080, -2, 6)
        XCTAssertEqual(value.netWh, 2, accuracy: 1e-12)
        XCTAssertEqual(value.dischargeWh, 2, accuracy: 1e-12)
        XCTAssertEqual(value.regenerationWh, 0)
        XCTAssertEqual(value.netAh, 20 / 3_600, accuracy: 1e-12)
        XCTAssertEqual(try JSONDecoder().decode(RangeElectricalSpan.self,
                       from: JSONEncoder().encode(value)), value)
        let driving = interval(spans: [value])
        XCTAssertEqual(try JSONDecoder().decode(RangeDrivingInterval.self,
                       from: JSONEncoder().encode(driving)), driving)
    }

    func testCrossZeroSplitsExactTrianglesInBothDirections() {
        for value in [span(0, 10, 3_600, -1_800), span(0, 10, -1_800, 3_600)] {
            XCTAssertEqual(value.netWh, 2.5, accuracy: 1e-12)
            XCTAssertEqual(value.dischargeWh, 10 / 3, accuracy: 1e-12)
            XCTAssertEqual(value.regenerationWh, 5 / 6, accuracy: 1e-12)
            XCTAssertEqual(value.netWh, value.dischargeWh - value.regenerationWh,
                           accuracy: 1e-12)
        }
        XCTAssertEqual(span(0, 10, 0, 3_600).dischargeWh, 5)
        XCTAssertEqual(span(0, 10, -3_600, 0).regenerationWh, 5)
    }

    func testSpanClippingInterpolatesPowerAndCurrentBeforeIntegration() throws {
        let result = try XCTUnwrap(span(0, 10, 3_600, -3_600, 10, -10)
            .clipped(start: date(2.5), end: date(7.5)))
        XCTAssertEqual(result, span(2.5, 7.5, 1_800, -1_800, 5, -5))
        XCTAssertEqual(result.netWh, 0, accuracy: 1e-12)
        XCTAssertEqual(result.dischargeWh, 0.625, accuracy: 1e-12)
        XCTAssertEqual(result.regenerationWh, 0.625, accuracy: 1e-12)
        XCTAssertEqual(result.netAh, 0, accuracy: 1e-12)
        let whole = span(0, 10)
        XCTAssertEqual(whole.clipped(start: date(-10), end: date(20)), whole)
    }

    func testClippingRejectsEmptyReversedNonFiniteAndDisjointBounds() {
        let value = span(0, 10)
        let driving = interval()
        for (start, end) in [(10.0, 20.0), (-10, 0), (5, 5), (8, 2),
                             (.nan, 5), (0, .infinity), (-.infinity, 10)] {
            XCTAssertNil(value.clipped(start: date(start), end: date(end)))
            XCTAssertNil(driving.clipped(start: date(start), end: date(end)))
        }
        XCTAssertNil(span(0, 0).clipped(start: date(0), end: date(10)))
        XCTAssertNil(span(0, 10, .nan).clipped(start: date(0), end: date(10)))
        XCTAssertNil(interval(spans: []).clipped(start: date(0), end: date(10)))
        XCTAssertNil(interval(distance: .nan).clipped(start: date(0), end: date(10)))
    }

    func testIntervalClippingProratesDistanceAndClipsEachSpan() throws {
        let value = interval(distance: 100, spans: [span(0, 4, 3_600, 3_600),
                                                  span(4, 10, 3_600, -3_600)])
        let result = try XCTUnwrap(value.clipped(start: date(2), end: date(8)))
        XCTAssertEqual(result.startedAt, date(2))
        XCTAssertEqual(result.endedAt, date(8))
        XCTAssertEqual(result.duration, 6)
        XCTAssertEqual(result.distanceMeters, 60)
        XCTAssertEqual(result.electricalSpans.count, 2)
        XCTAssertEqual(result.electricalSpans[0], span(2, 4, 3_600, 3_600))
        XCTAssertEqual(result.electricalSpans[1].startedAt, date(4))
        XCTAssertEqual(result.electricalSpans[1].endedAt, date(8))
        XCTAssertEqual(result.electricalSpans[1].startPowerW, 3_600, accuracy: 1e-9)
        XCTAssertEqual(result.electricalSpans[1].endPowerW, -1_200, accuracy: 1e-9)
        XCTAssertEqual(result.netWh, 10 / 3, accuracy: 1e-12)
        XCTAssertEqual(result.dischargeWh, 3.5, accuracy: 1e-12)
        XCTAssertEqual(result.regenerationWh, 1 / 6, accuracy: 1e-12)
    }

    func testMeasuredNetAhOverridesCurrentIntegralAndClipsProportionally() throws {
        let spans = [span(0, 10, 1_800, 1_800, 18, 18)]
        let value = RangeDrivingInterval(startedAt: date(0), endedAt: date(10),
                                         distanceMeters: 100, electricalSpans: spans, netAh: 3)
        XCTAssertEqual(value.measuredNetAh, 3)
        XCTAssertEqual(value.netAh, 3)
        XCTAssertEqual(value.netWh, 5)
        XCTAssertEqual(value.electricalSpans, spans)
        let clipped = try XCTUnwrap(value.clipped(start: date(5), end: date(10)))
        XCTAssertEqual(clipped.measuredNetAh, 1.5)
        XCTAssertEqual(clipped.netAh, 1.5)
        XCTAssertEqual(clipped.distanceMeters, 50)
        XCTAssertEqual(try JSONDecoder().decode(RangeDrivingInterval.self,
                       from: JSONEncoder().encode(value)), value)
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(value))
        result.trim(to: 5)
        XCTAssertEqual(result.summary.netAh, 1.5)
    }

    func testNegativeAndZeroMeasuredNetAhAreAcceptedWithoutChangingEnergy() {
        for measured in [-3.0, 0] {
            var result = RangeDrivingWindow()
            let value = RangeDrivingInterval(startedAt: date(0), endedAt: date(10),
                                             distanceMeters: 100, electricalSpans: [span(0, 10)],
                                             netAh: measured)
            XCTAssertTrue(result.append(value))
            XCTAssertEqual(result.summary.netAh, measured)
            XCTAssertEqual(result.summary.netWh, 5)
            XCTAssertEqual(result.summary.dischargeWh, 5)
        }
        XCTAssertNil(interval().measuredNetAh)
        XCTAssertEqual(interval().netAh, 0.05, accuracy: 1e-12)
    }

    func testNonFiniteMeasuredNetAhIsRejectedByAppendAndClip() {
        for measured in [Double.nan, .infinity, -.infinity] {
            let value = RangeDrivingInterval(startedAt: date(0), endedAt: date(10),
                                             distanceMeters: 100, electricalSpans: [span(0, 10)],
                                             netAh: measured)
            var result = RangeDrivingWindow()
            XCTAssertFalse(result.append(value))
            XCTAssertNil(value.clipped(start: date(0), end: date(5)))
        }
    }

    func testLegacyCodableIntervalWithoutMeasuredAhKeepsCurrentFallback() throws {
        let data = try JSONEncoder().encode(interval())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "measuredNetAh")
        let restored = try JSONDecoder().decode(RangeDrivingInterval.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.measuredNetAh)
        XCTAssertEqual(restored.netAh, 0.05, accuracy: 1e-12)
    }

    func testExactMinimumDrivingSpeedIsAcceptedAndBelowIsRejected() {
        let distance = 10 * (3.0 / 3.6)
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(distance: distance)))
        var below = RangeDrivingWindow()
        XCTAssertFalse(below.append(interval(distance: distance.nextDown)))
        XCTAssertEqual(RangeDrivingWindow.minimumAverageSpeedKmh, 3)
    }

    func testWindowMetricConveniencesMatchSummary() {
        let result = window()
        XCTAssertEqual(result.duration, result.summary.duration)
        XCTAssertEqual(result.distanceMeters, result.summary.distanceMeters)
        XCTAssertEqual(result.netWh, result.summary.netWh)
        XCTAssertEqual(result.dischargeWh, result.summary.dischargeWh)
        XCTAssertEqual(result.regenerationWh, result.summary.regenerationWh)
        XCTAssertEqual(result.netAh, result.summary.netAh)
    }

    func testPredictionThresholdsAreInclusiveAndIndependentlyRequired() {
        let exact = window()
        XCTAssertEqual(exact.summary.duration, 30)
        XCTAssertEqual(exact.summary.distanceMeters, 200)
        XCTAssertEqual(exact.summary.dischargeWh, 5, accuracy: 1e-12)
        XCTAssertEqual(exact.predictionStatus, .valid)
        XCTAssertEqual(window(lastDuration: 9.999).predictionStatus, .accumulating)
        XCTAssertEqual(window(distance: 199.999).predictionStatus, .accumulating)
        XCTAssertEqual(window(power: 599.999).predictionStatus, .accumulating)
        XCTAssertEqual(RangeDrivingWindow.minimumPredictionDuration, 30)
        XCTAssertEqual(RangeDrivingWindow.minimumPredictionDistanceMeters, 200)
        XCTAssertEqual(RangeDrivingWindow.minimumPredictionDischargeWh, 5)
        XCTAssertEqual(RangeDrivingWindow.minimumPredictionNetWh, 5)
    }

    func testRegenerationReducesNetEnergyAndChangesPredictionStatus() {
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(0, 10, power: 3_600)))
        XCTAssertTrue(result.append(interval(10, 20, power: 3_600)))
        XCTAssertTrue(result.append(interval(20, 30, power: -1_800)))
        XCTAssertEqual(result.summary.dischargeWh, 20)
        XCTAssertEqual(result.summary.regenerationWh, 5)
        XCTAssertEqual(result.summary.netWh, 15)
        XCTAssertEqual(result.predictionStatus, .valid)
        XCTAssertTrue(result.append(interval(30, 40, power: -3_600)))
        XCTAssertEqual(result.summary.netWh, 5)
        XCTAssertEqual(result.predictionStatus, .valid)
        XCTAssertTrue(result.append(interval(40, 50, power: -0.001)))
        XCTAssertEqual(result.predictionStatus, .nonPositiveNetEnergy)
    }

    func testNonPositiveNetEnergyAfterMinimumEvidenceIsNotAccumulating() {
        for regenerationPower in [-3_600.0, -7_200] {
            var result = RangeDrivingWindow()
            XCTAssertTrue(result.append(interval(0, 10, power: 3_600)))
            XCTAssertTrue(result.append(interval(10, 20, power: 0)))
            XCTAssertTrue(result.append(interval(20, 30, power: regenerationPower)))
            XCTAssertGreaterThanOrEqual(result.summary.dischargeWh, 5)
            XCTAssertLessThanOrEqual(result.summary.netWh, 0)
            XCTAssertEqual(result.predictionStatus, .nonPositiveNetEnergy)
        }
    }

    func testClippingExactlyAtZeroKeepsOnlyTheCorrectEnergyDirection() throws {
        let value = span(0, 10, 3_600, -3_600, 36, -36)
        let discharge = try XCTUnwrap(value.clipped(start: date(0), end: date(5)))
        let regeneration = try XCTUnwrap(value.clipped(start: date(5), end: date(10)))
        XCTAssertEqual(discharge.dischargeWh, 2.5)
        XCTAssertEqual(discharge.regenerationWh, 0)
        XCTAssertEqual(regeneration.dischargeWh, 0)
        XCTAssertEqual(regeneration.regenerationWh, 2.5)
        XCTAssertEqual(discharge.netAh, 0.025, accuracy: 1e-12)
        XCTAssertEqual(regeneration.netAh, -0.025, accuracy: 1e-12)
    }

    func testPureRegenerationAndZeroPowerAreAccepted() {
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(power: -3_600)))
        XCTAssertEqual(result.summary.netWh, -10)
        XCTAssertEqual(result.summary.dischargeWh, 0)
        XCTAssertEqual(result.summary.regenerationWh, 10)
        XCTAssertEqual(result.predictionStatus, .accumulating)
        XCTAssertTrue(result.append(interval(10, 20, power: 0)))
    }

    func testParkingDoesNotAdvanceOrEvictWindowAndLongStopDoesNotExpireIt() {
        var result = window()
        let before = result.intervals
        let summary = result.summary
        XCTAssertFalse(result.append(interval(30, 40, distance: 0)))
        XCTAssertFalse(result.append(interval(100_000, 100_010, distance: 0)))
        result.trim(to: 30)
        XCTAssertEqual(result.intervals, before)
        XCTAssertEqual(result.summary.duration, summary.duration)
        XCTAssertEqual(result.predictionStatus, .valid)
        XCTAssertTrue(result.append(interval(100_010, 100_020)))
        result.trim(to: 30)
        XCTAssertEqual(result.intervals.map(\.startedAt), [date(10), date(20), date(100_010)])
        XCTAssertEqual(result.summary.duration, 30)
    }

    func testPartialFIFOReintegratesCrossZeroAndMultipleSpans() {
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(distance: 100, spans: [
            span(0, 4, 3_600, 3_600, 36, 36),
            span(4, 10, 3_600, -3_600, 36, -36)
        ])))
        XCTAssertTrue(result.append(interval(10, 20, distance: 200, power: 0)))
        result.trim(to: 18)
        XCTAssertEqual(result.intervals.count, 2)
        XCTAssertEqual(result.intervals[0].startedAt, date(2))
        XCTAssertEqual(result.intervals[0].electricalSpans.count, 2)
        XCTAssertEqual(result.summary.duration, 18)
        XCTAssertEqual(result.summary.distanceMeters, 280)
        XCTAssertEqual(result.summary.netWh, 2, accuracy: 1e-12)
        XCTAssertEqual(result.summary.dischargeWh, 3.5, accuracy: 1e-12)
        XCTAssertEqual(result.summary.regenerationWh, 1.5, accuracy: 1e-12)
        XCTAssertEqual(result.summary.netAh, 0.07, accuracy: 1e-12)
        result.trim(to: 15)
        XCTAssertEqual(result.intervals[0].startedAt, date(5))
        XCTAssertEqual(result.intervals[0].electricalSpans, [span(5, 10, 2_400, -3_600, 24, -36)])
        XCTAssertEqual(result.summary.distanceMeters, 250)
        XCTAssertEqual(result.summary.netWh, -5 / 6, accuracy: 1e-12)
        XCTAssertEqual(result.summary.dischargeWh, 2 / 3, accuracy: 1e-12)
        XCTAssertEqual(result.summary.regenerationWh, 1.5, accuracy: 1e-12)
        XCTAssertEqual(result.summary.netAh, 1 / 24, accuracy: 1e-12)
    }

    func testFIFOUsesEffectiveDurationRatherThanWallClockGaps() {
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(0, 10)))
        XCTAssertTrue(result.append(interval(1_000, 1_010)))
        result.trim(to: 15)
        XCTAssertEqual(result.intervals[0].startedAt, date(5))
        XCTAssertEqual(result.summary.duration, 15)
        result.trim(to: 10)
        XCTAssertEqual(result.intervals, [interval(1_000, 1_010)])
    }

    func testTrimNoOpClearAndEmptySummary() {
        var result = window()
        let before = result.intervals
        for duration in [100.0, 30, .infinity, .nan] {
            result.trim(to: duration)
            XCTAssertEqual(result.intervals, before)
        }
        result.trim(to: 0)
        XCTAssertTrue(result.intervals.isEmpty)
        XCTAssertEqual(result.summary.duration, 0)
        XCTAssertEqual(result.summary.distanceMeters, 0)
        XCTAssertEqual(result.summary.netWh, 0)
        XCTAssertEqual(result.summary.dischargeWh, 0)
        XCTAssertEqual(result.summary.regenerationWh, 0)
        XCTAssertEqual(result.summary.netAh, 0)
        XCTAssertEqual(result.predictionStatus, .noValidIntervals)
        XCTAssertTrue(result.append(interval()))
        result.clear()
        XCTAssertTrue(result.intervals.isEmpty)
        XCTAssertTrue(result.append(interval()))
        result.trim(to: -1)
        XCTAssertTrue(result.intervals.isEmpty)
    }

    func testDuplicateOverlapAndOutOfOrderAreRejectedWithoutMutation() {
        var result = RangeDrivingWindow()
        let first = interval()
        XCTAssertTrue(result.append(first))
        for value in [first, interval(5, 15), interval(-10, 0), interval(9, 10)] {
            XCTAssertFalse(result.append(value))
            XCTAssertEqual(result.intervals, [first])
        }
        XCTAssertTrue(result.append(interval(10, 20)))
    }

    func testIntervalUpperBoundsAreInclusive() {
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(distance: 2_000)))
        XCTAssertEqual(RangeDrivingWindow.maximumIntervalDuration, 10)
        XCTAssertEqual(RangeDrivingWindow.maximumIntervalDistanceMeters, 2_000)
        for value in [interval(0, 10.001), interval(distance: 2_000.0001),
                      interval(0, 0), interval(10, 0), interval(distance: -1)] {
            var rejected = RangeDrivingWindow()
            XCTAssertFalse(rejected.append(value))
        }
    }

    func testFiniteInputsAndFiniteDerivedIntegralsAreRequired() {
        let invalidValues: [RangeDrivingInterval] = [
            interval(.nan, 10), interval(0, .infinity), interval(distance: .nan),
            interval(distance: .infinity), interval(power: .nan), interval(power: .infinity),
            interval(spans: [span(0, 10, 1, 1, .nan, 1)]),
            interval(spans: [span(0, 10, 1, 1, 1, .infinity)])
        ]
        for value in invalidValues {
            var result = RangeDrivingWindow()
            XCTAssertFalse(result.append(value))
            XCTAssertTrue(result.intervals.isEmpty)
        }
    }

    func testElectricalSpansMustCoverIntervalInOrderWithoutGapsOrOverlap() {
        for spans in [[], [span(1, 10)], [span(0, 9)], [span(-1, 10)], [span(0, 11)],
                      [span(0, 4), span(5, 10)], [span(0, 6), span(5, 10)],
                      [span(5, 10), span(0, 5)], [span(0, 5), span(5, 5), span(5, 10)],
                      [span(0, 10), span(0, 10)]] as [[RangeElectricalSpan]] {
            var result = RangeDrivingWindow()
            XCTAssertFalse(result.append(interval(spans: spans)))
        }
        var result = RangeDrivingWindow()
        XCTAssertTrue(result.append(interval(spans: [span(0, 5), span(5, 10)])))
    }
}
