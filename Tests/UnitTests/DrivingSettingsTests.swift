import XCTest
@testable import ANTuRideDomain

final class DrivingSettingsTests: XCTestCase {
    func testAndroidDefaultsAreRepresentedExactly() throws {
        let settings = DrivingSettings.defaults
        XCTAssertEqual(settings.rangeWindowMinutes, 15)
        XCTAssertEqual(settings.rangeRefreshSeconds, 10)
        XCTAssertEqual(settings.valueScale, 1)
        XCTAssertFalse(settings.showTextDescriptions)
        XCTAssertEqual(settings.defaultPowerDisplayMode, .curve)
        XCTAssertEqual(settings.appThemeMode, .system)
        XCTAssertEqual(settings.bluetoothRefreshIntervalMs, 1000)
        XCTAssertEqual(settings.temperatureSource, "自动")
        XCTAssertEqual(settings.dischargeBaseW, 6000)
        XCTAssertEqual(settings.chargeBaseW, 2500)
        XCTAssertEqual(settings.powerYellowStart, 0.55)
        XCTAssertEqual(settings.powerRedStart, 0.90)
        XCTAssertEqual(settings.socRedUpperPercent, 10)
        XCTAssertEqual(settings.socYellowUpperPercent, 20)
        XCTAssertEqual(settings.diffGreenUpperMv, 20)
        XCTAssertEqual(settings.diffYellowUpperMv, 50)
        XCTAssertEqual(settings.tempGreenUpperC, 39)
        XCTAssertEqual(settings.tempYellowUpperC, 45)
        XCTAssertEqual(settings.powerHeaderSpeedBaseKmh, 80)
        XCTAssertEqual(settings.powerHeaderSpeedMidKmh, 30)
        XCTAssertEqual(settings.powerHeaderSpeedHighKmh, 60)
        XCTAssertTrue(settings.bmsAutoConnectEnabled)
        XCTAssertTrue(settings.controllerAutoConnectEnabled)
        XCTAssertTrue(settings.isValid)
    }

    func testCodableRoundTripPreservesAllSettings() throws {
        var original = DrivingSettings()
        original.rangeWindowMinutes = 60
        original.rangeRefreshSeconds = 30
        original.valueScale = 1.25
        original.showTextDescriptions = true
        original.defaultPowerDisplayMode = .powerBar
        original.appThemeMode = .dark
        original.bluetoothRefreshIntervalMs = 60000
        original.temperatureSource = "探头 2"
        original.dischargeBaseW = 7000
        original.chargeBaseW = 3000
        original.powerYellowStart = 0.4
        original.powerRedStart = 0.8
        original.socRedUpperPercent = 15
        original.socYellowUpperPercent = 35
        original.diffGreenUpperMv = 25
        original.diffYellowUpperMv = 80
        original.tempGreenUpperC = 40
        original.tempYellowUpperC = 55
        original.powerHeaderSpeedBaseKmh = 100
        original.powerHeaderSpeedMidKmh = 40
        original.powerHeaderSpeedHighKmh = 70
        original.bmsAutoConnectEnabled = false
        original.controllerAutoConnectEnabled = false

        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DrivingSettings.self, from: data), original)
    }

    func testValidationRejectsOutOfRangeAndUnorderedThresholds() {
        var settings = DrivingSettings()
        settings.rangeWindowMinutes = 2
        settings.rangeRefreshSeconds = 61
        settings.bluetoothRefreshIntervalMs = 99
        settings.valueScale = 2.1
        settings.powerYellowStart = 0.9
        settings.powerRedStart = 0.8
        settings.socRedUpperPercent = 30
        settings.socYellowUpperPercent = 20
        settings.diffGreenUpperMv = 50
        settings.diffYellowUpperMv = 20
        settings.tempGreenUpperC = 50
        settings.tempYellowUpperC = 40
        settings.powerHeaderSpeedMidKmh = 90
        settings.powerHeaderSpeedHighKmh = 80

        XCTAssertFalse(settings.isValid)
        XCTAssertThrowsError(try settings.validate()) { error in
            XCTAssertGreaterThan((error as? DrivingSettings.ValidationError)?.messages.count ?? 0, 5)
        }
    }

    func testNormalizedRecoversLegacyOrCorruptValuesWithoutChangingDefaults() {
        var settings = DrivingSettings()
        settings.rangeWindowMinutes = 100
        settings.rangeRefreshSeconds = 0
        settings.bluetoothRefreshIntervalMs = 100_000
        settings.valueScale = .nan
        settings.powerRedStart = -1
        settings.socYellowUpperPercent = 101
        settings.diffYellowUpperMv = -1
        settings.tempGreenUpperC = 999
        settings.powerHeaderSpeedBaseKmh = .infinity
        settings.powerHeaderSpeedMidKmh = 999
        settings.temperatureSource = "   "

        let normalized = settings.normalized()
        XCTAssertEqual(normalized.rangeWindowMinutes, 60)
        XCTAssertEqual(normalized.rangeRefreshSeconds, 10)
        XCTAssertEqual(normalized.bluetoothRefreshIntervalMs, 60000)
        XCTAssertEqual(normalized.valueScale, 1)
        XCTAssertEqual(normalized.powerRedStart, 0.55)
        XCTAssertEqual(normalized.socYellowUpperPercent, 100)
        XCTAssertEqual(normalized.diffYellowUpperMv, 20)
        XCTAssertEqual(normalized.tempGreenUpperC, 150)
        XCTAssertEqual(normalized.powerHeaderSpeedBaseKmh, 80)
        XCTAssertEqual(normalized.temperatureSource, "自动")
        XCTAssertTrue(normalized.isValid)
    }

    func testInclusiveBoundsAndEqualThresholdsAreValid() throws {
        for upper in [false, true] {
            var settings = DrivingSettings()
            settings.rangeWindowMinutes = upper ? 60 : 3
            settings.rangeRefreshSeconds = upper ? 60 : 10
            settings.bluetoothRefreshIntervalMs = upper ? 60_000 : 100
            settings.valueScale = upper ? 2 : 0.5
            settings.dischargeBaseW = 1
            settings.chargeBaseW = 1
            settings.powerYellowStart = upper ? 1 : 0
            settings.powerRedStart = settings.powerYellowStart
            settings.socRedUpperPercent = upper ? 100 : 0
            settings.socYellowUpperPercent = settings.socRedUpperPercent
            settings.diffGreenUpperMv = 0
            settings.diffYellowUpperMv = 0
            settings.tempGreenUpperC = upper ? 150 : -50
            settings.tempYellowUpperC = settings.tempGreenUpperC
            settings.powerHeaderSpeedBaseKmh = upper ? 300 : 1
            settings.powerHeaderSpeedMidKmh = upper ? 300 : 0
            settings.powerHeaderSpeedHighKmh = settings.powerHeaderSpeedMidKmh
            try settings.validate()
            XCTAssertEqual(settings.normalized(), settings)
        }
    }

    func testEveryDoubleRejectsNonFiniteValuesAndNormalizationIsIdempotent() {
        let keys: [WritableKeyPath<DrivingSettings, Double>] = [
            \.valueScale, \.dischargeBaseW, \.chargeBaseW, \.powerYellowStart, \.powerRedStart,
            \.socRedUpperPercent, \.socYellowUpperPercent, \.diffGreenUpperMv, \.diffYellowUpperMv,
            \.tempGreenUpperC, \.tempYellowUpperC, \.powerHeaderSpeedBaseKmh,
            \.powerHeaderSpeedMidKmh, \.powerHeaderSpeedHighKmh
        ]
        for key in keys {
            for value in [Double.nan, .infinity, -.infinity] {
                var settings = DrivingSettings()
                settings[keyPath: key] = value
                XCTAssertFalse(settings.isValid)
                XCTAssertThrowsError(try settings.validate())
                let safe = settings.normalized()
                XCTAssertTrue(safe.isValid)
                XCTAssertEqual(safe.normalized(), safe)
            }
        }
    }

    func testEachNumericLimitRejectsOutsideValues() {
        let integerLimits: [(WritableKeyPath<DrivingSettings, Int>, ClosedRange<Int>)] = [
            (\.rangeWindowMinutes, 3...60), (\.rangeRefreshSeconds, 10...60),
            (\.bluetoothRefreshIntervalMs, 100...60_000)
        ]
        for (key, bounds) in integerLimits {
            for value in [Int.min, bounds.lowerBound - 1, bounds.upperBound + 1, Int.max] {
                var settings = DrivingSettings()
                settings[keyPath: key] = value
                XCTAssertFalse(settings.isValid)
                XCTAssertTrue(settings.normalized().isValid)
            }
        }
        let invalidDoubles: [(WritableKeyPath<DrivingSettings, Double>, [Double])] = [
            (\.valueScale, [0.49, 2.01]), (\.dischargeBaseW, [0.99]), (\.chargeBaseW, [-1]),
            (\.powerYellowStart, [-0.01, 1.01]), (\.powerRedStart, [-0.01, 1.01]),
            (\.socRedUpperPercent, [-1, 101]), (\.socYellowUpperPercent, [-1, 101]),
            (\.diffGreenUpperMv, [-1]), (\.diffYellowUpperMv, [-1]),
            (\.tempGreenUpperC, [-51, 151]), (\.tempYellowUpperC, [-51, 151]),
            (\.powerHeaderSpeedBaseKmh, [0, 301]), (\.powerHeaderSpeedMidKmh, [-1, 81]),
            (\.powerHeaderSpeedHighKmh, [-1, 81])
        ]
        for (key, values) in invalidDoubles {
            for value in values {
                var settings = DrivingSettings()
                settings[keyPath: key] = value
                XCTAssertFalse(settings.isValid)
                XCTAssertTrue(settings.normalized().isValid)
            }
        }
    }

    func testAndroidDoesNotImposeInventedPowerOrDifferenceUpperBounds() throws {
        var settings = DrivingSettings()
        settings.dischargeBaseW = 1_000_000
        settings.chargeBaseW = 1_000_000
        settings.diffGreenUpperMv = 1_000_000
        settings.diffYellowUpperMv = 2_000_000
        try settings.validate()
        XCTAssertEqual(settings.normalized(), settings)
    }

    func testBlankTemperatureSourceFallsBackButProbeSelectionRemainsText() {
        var settings = DrivingSettings()
        settings.temperatureSource = " \n\t "
        XCTAssertEqual(settings.normalized().temperatureSource, "自动")
        settings.temperatureSource = "  探头 99  "
        XCTAssertEqual(settings.normalized().temperatureSource, "探头 99")
    }

    func testAutoConnectionPreferencesAreIndependentAndDoNotContainDeviceIdentity() throws {
        var settings = DrivingSettings()
        settings.bmsAutoConnectEnabled = false
        XCTAssertTrue(settings.controllerAutoConnectEnabled)
        settings.controllerAutoConnectEnabled = false
        settings.bmsAutoConnectEnabled = true
        XCTAssertFalse(settings.controllerAutoConnectEnabled)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(json.count, 23)
        XCTAssertFalse(json.keys.contains { $0.lowercased().contains("uuid") || $0.lowercased().contains("address") })
    }

    func testEnumsRoundTripWithAndroidNamesAndRejectUnknownValues() throws {
        XCTAssertEqual(try JSONDecoder().decode(DrivingSettings.ThemeMode.self, from: Data("\"LIGHT\"".utf8)), .light)
        XCTAssertEqual(try JSONDecoder().decode(DrivingSettings.PowerDisplayMode.self, from: Data("\"POWER_BAR\"".utf8)), .powerBar)
        XCTAssertThrowsError(try JSONDecoder().decode(DrivingSettings.ThemeMode.self, from: Data("\"unknown\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(DrivingSettings.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(DrivingSettings.self, from: Data("broken JSON".utf8)))
    }
    func testRestoreDefaultsReplacesEveryField() {
        var settings = DrivingSettings()
        settings.rangeWindowMinutes = 3
        settings.rangeRefreshSeconds = 60
        settings.bluetoothRefreshIntervalMs = 100
        let keys: [WritableKeyPath<DrivingSettings, Double>] = [
            \.valueScale, \.dischargeBaseW, \.chargeBaseW, \.powerYellowStart, \.powerRedStart,
            \.socRedUpperPercent, \.socYellowUpperPercent, \.diffGreenUpperMv, \.diffYellowUpperMv,
            \.tempGreenUpperC, \.tempYellowUpperC, \.powerHeaderSpeedBaseKmh,
            \.powerHeaderSpeedMidKmh, \.powerHeaderSpeedHighKmh
        ]
        for key in keys { settings[keyPath: key] = -999 }
        settings.appThemeMode = .light
        settings.defaultPowerDisplayMode = .powerBar
        settings.temperatureSource = "探头 99"
        settings.showTextDescriptions = true
        settings.bmsAutoConnectEnabled = false
        settings.controllerAutoConnectEnabled = false
        settings.restoreDefaults()
        XCTAssertEqual(settings, .defaults)
    }
}
