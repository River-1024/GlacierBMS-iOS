import XCTest
@testable import ANTuRideDomain

final class RangeModelsTests: XCTestCase {
    func testExplicitAndroidEnergyOverridesLegacyCoefficient() {
        let predictor = BasicRangePredictor(settings: RangeSettings(nominalCapacityAh: 134, deviceID: "a"))
        let energy = AndroidEnergyCurve.remainingEnergyWh(remainingAh: 50, capacityAh: 134)!
        let result = predictor.predict(remainingAh: 50, netWh: 100, distanceMeters: 1_000,
                                       remainingEnergyWh: energy)
        XCTAssertEqual(result.predictedRangeKm!, energy / 100, accuracy: 1e-9)
        XCTAssertNotEqual(result.predictedRangeKm!, 50 * 66 / 100)
    }

    func testExplicitInvalidEnergyCannotProduceRange() {
        let predictor = BasicRangePredictor(settings: RangeSettings(nominalCapacityAh: 134, deviceID: "a"))
        for energy in [Double.nan, .infinity, -1] {
            XCTAssertEqual(predictor.predict(remainingAh: 50, netWh: 100, distanceMeters: 1_000,
                                            remainingEnergyWh: energy).status, .capacityInvalid)
        }
        XCTAssertEqual(predictor.predict(remainingAh: 0, netWh: 100, distanceMeters: 1_000,
                                        remainingEnergyWh: 1).status, .capacityInvalid)
        XCTAssertEqual(predictor.predict(remainingAh: 0, netWh: 100, distanceMeters: 1_000,
                                        remainingEnergyWh: 0).predictedRangeKm, 0)
    }

    private let settings = RangeSettings(nominalCapacityAh: 100, deviceID: "bms-a")

    private var predictor: BasicRangePredictor { BasicRangePredictor(settings: settings) }

    private func assertUnavailable(
        _ prediction: RangePrediction,
        _ status: RangePredictionStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(prediction.status, status, file: file, line: line)
        XCTAssertEqual(prediction.stopReason, status, file: file, line: line)
        XCTAssertNil(prediction.predictedRangeKm, file: file, line: line)
        XCTAssertEqual(prediction.reason, status, file: file, line: line)
        XCTAssertEqual(prediction.reasonText, status.reason, file: file, line: line)
        XCTAssertFalse(prediction.reasonText.isEmpty, file: file, line: line)
    }

    func testAllRequiredStatusesHaveDistinctReasons() {
        XCTAssertEqual(Set(RangePredictionStatus.allCases.map(\.rawValue)), Set([
            "valid", "telemetryStale", "noValidIntervals", "charging", "capacityInvalid",
            "undervoltage", "disconnected", "nonPositiveNetEnergy", "accumulating"
        ]))
        XCTAssertEqual(Set(RangePredictionStatus.allCases.map(\.reason)).count, 9)
    }

    func testSettingsPreserveCapacityAndDeviceIdentityAndRoundTrip() throws {
        XCTAssertEqual(predictor.settings, settings)
        XCTAssertEqual(settings.nominalCapacityAh, 100)
        XCTAssertEqual(settings.deviceID, "bms-a")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(RangeSettings.self, from: data), settings)
        XCTAssertNotEqual(settings, RangeSettings(nominalCapacityAh: 100, deviceID: "bms-b"))
    }

    func testValidWindowUsesConservativeLowerBoundAndMetersToKilometers() throws {
        let prediction = predictor.predict(remainingAh: 50, netWh: 100, distanceMeters: 2_000)
        XCTAssertEqual(prediction.status, .valid)
        XCTAssertEqual(try XCTUnwrap(prediction.predictedRangeKm), 66, accuracy: 1e-12)
        XCTAssertEqual(prediction.reason, .valid)
        XCTAssertEqual(prediction.reasonText, RangePredictionStatus.valid.reason)
    }

    func testEffectiveWhPerAhBoundsAreInclusive() throws {
        XCTAssertEqual(BasicRangePredictor.effectiveWhPerAhBounds, 66...86)
        for coefficient in [66.0, 76.0, 86.0] {
            let model = BasicRangePredictor(settings: settings, effectiveWhPerAh: coefficient)
            let prediction = model.predict(remainingAh: 50, netWh: 100, distanceMeters: 2_000)
            XCTAssertEqual(prediction.status, .valid)
            XCTAssertEqual(try XCTUnwrap(prediction.predictedRangeKm), coefficient, accuracy: 1e-12)
        }
    }

    func testInvalidEffectiveCoefficientsAreRejectedNotClamped() {
        for coefficient in [66.0.nextDown, 86.0.nextUp, 0, -1, .nan, .infinity, -.infinity] {
            let model = BasicRangePredictor(settings: settings, effectiveWhPerAh: coefficient)
            assertUnavailable(model.predict(
                remainingAh: 50, netWh: 100, distanceMeters: 2_000
            ), .capacityInvalid)
        }
    }

    func testSafetyFlagsSuppressOtherwiseValidPrediction() {
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: 2_000, stale: true
        ), .telemetryStale)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: 2_000, disconnected: true
        ), .disconnected)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: 2_000, charging: true
        ), .charging)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: 2_000, undervoltage: true
        ), .undervoltage)
    }

    func testStopReasonPrecedenceIsDeterministic() {
        assertUnavailable(predictor.predict(
            remainingAh: .nan, netWh: .nan, distanceMeters: .nan,
            stale: true, disconnected: true, charging: true, undervoltage: true
        ), .disconnected)
        assertUnavailable(predictor.predict(
            remainingAh: .nan, netWh: .nan, distanceMeters: .nan,
            stale: true, charging: true, undervoltage: true
        ), .telemetryStale)
        assertUnavailable(predictor.predict(
            remainingAh: .nan, netWh: .nan, distanceMeters: .nan,
            charging: true, undervoltage: true
        ), .charging)
        assertUnavailable(predictor.predict(
            remainingAh: .nan, netWh: .nan, distanceMeters: .nan, undervoltage: true
        ), .undervoltage)
    }

    func testInvalidNominalCapacityDoesNotProduceFallbackRange() {
        for capacity in [0.0, -1, .nan, .infinity, -.infinity] {
            let model = BasicRangePredictor(settings: RangeSettings(
                nominalCapacityAh: capacity, deviceID: "bms-a"
            ))
            assertUnavailable(model.predict(
                remainingAh: 0, netWh: 100, distanceMeters: 2_000
            ), .capacityInvalid)
        }
    }

    func testInvalidRemainingAhIsRejectedNotClamped() {
        for remainingAh in [-1.0, 100.0.nextUp, .nan, .infinity, -.infinity] {
            assertUnavailable(predictor.predict(
                remainingAh: remainingAh, netWh: 100, distanceMeters: 2_000
            ), .capacityInvalid)
        }
    }

    func testEmptyWindowIsAccumulatingWithoutFakeZero() {
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 0, distanceMeters: 0
        ), .accumulating)
    }

    func testStationaryEnergyIsNotDrivingEvidence() {
        for netWh in [100.0, -100] {
            assertUnavailable(predictor.predict(
                remainingAh: 50, netWh: netWh, distanceMeters: 0
            ), .noValidIntervals)
        }
    }

    func testNegativeOrNonFiniteDistanceIsNotValidEvidence() {
        for distance in [-1.0, .nan, .infinity, -.infinity] {
            assertUnavailable(predictor.predict(
                remainingAh: 50, netWh: 100, distanceMeters: distance
            ), .noValidIntervals)
        }
    }

    func testNonFiniteEnergyIsNotValidEvidence() {
        for energy in [Double.nan, .infinity, -.infinity] {
            assertUnavailable(predictor.predict(
                remainingAh: 50, netWh: energy, distanceMeters: 2_000
            ), .noValidIntervals)
        }
    }

    func testNonPositiveNetEnergyDoesNotProduceInfiniteOrNegativeRange() {
        for energy in [0.0, -0.0, -100] {
            assertUnavailable(predictor.predict(
                remainingAh: 50, netWh: energy, distanceMeters: 2_000
            ), .nonPositiveNetEnergy)
        }
    }

    func testPositiveWindowDoesNotRequireInventedMinimumSamples() throws {
        let prediction = predictor.predict(remainingAh: 1, netWh: 0.01, distanceMeters: 1)
        XCTAssertEqual(prediction.status, .valid)
        XCTAssertEqual(try XCTUnwrap(prediction.predictedRangeKm), 6.6, accuracy: 1e-12)
    }

    func testFullAndEmptyMeasuredCapacityAreValidWithDrivingEvidence() throws {
        let full = predictor.predict(remainingAh: 100, netWh: 100, distanceMeters: 2_000)
        XCTAssertEqual(full.status, .valid)
        XCTAssertEqual(try XCTUnwrap(full.predictedRangeKm), 132, accuracy: 1e-12)
        let empty = predictor.predict(remainingAh: 0, netWh: 100, distanceMeters: 2_000)
        XCTAssertEqual(empty.status, .valid)
        XCTAssertEqual(try XCTUnwrap(empty.predictedRangeKm), 0)
        assertUnavailable(predictor.predict(
            remainingAh: 0, netWh: 0, distanceMeters: 0
        ), .accumulating)
    }

    func testArithmeticOverflowAndUnderflowDoNotProduceFakeValues() {
        let large = Double.greatestFiniteMagnitude
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: large, distanceMeters: 1
        ), .noValidIntervals)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: Double.leastNonzeroMagnitude, distanceMeters: large
        ), .noValidIntervals)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: Double.leastNonzeroMagnitude
        ), .noValidIntervals)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: Double.leastNormalMagnitude, distanceMeters: 1_000
        ), .noValidIntervals)
        assertUnavailable(predictor.predict(
            remainingAh: Double.leastNonzeroMagnitude, netWh: large, distanceMeters: 1_000
        ), .noValidIntervals)
        let model = BasicRangePredictor(settings: RangeSettings(
            nominalCapacityAh: large, deviceID: "bms-a"
        ))
        assertUnavailable(model.predict(
            remainingAh: large, netWh: 100, distanceMeters: 2_000
        ), .capacityInvalid)
    }

    func testPredictionIsPureAndDoesNotRetainPreviousValidRange() {
        let valid = predictor.predict(remainingAh: 50, netWh: 100, distanceMeters: 2_000)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: 2_000, stale: true
        ), .telemetryStale)
        assertUnavailable(predictor.predict(
            remainingAh: 50, netWh: 0, distanceMeters: 0
        ), .accumulating)
        XCTAssertEqual(predictor.predict(
            remainingAh: 50, netWh: 100, distanceMeters: 2_000
        ), valid)
    }

    func testEarlyUIIntegrationCanUseStableStatusAndRangeFields() throws {
        let result = predictor.predict(remainingAh: 50, netWh: 100, distanceMeters: 2_000)
        XCTAssertEqual(result.stopReason, .valid)
        XCTAssertEqual(result.status, .valid)
        XCTAssertEqual(try XCTUnwrap(result.predictedRangeKm), 66, accuracy: 1e-12)
        XCTAssertFalse(result.reasonText.isEmpty)
    }
}
