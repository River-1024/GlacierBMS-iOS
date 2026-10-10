import XCTest
@testable import ANTuRideDomain

final class AndroidEnergyCurveTests: XCTestCase {
    // Python 从 Android 的 110 个原始十进制系数提取，用 Decimal(precision=50) 积分生成。
    // 独立黄金参考：索引为整数剩余 Ah (0...134)，不通过被测 Swift 实现生成期望值。
    private let integerEnergyWh: [Double] = [
        0.0, 66.07321112420743, 132.29114439409102, 198.65129370949884,
        265.15121170888705, 331.78850976932006, 398.5608580064702, 465.4659852746182,
        532.5016791666528, 599.6657860140709, 666.9562108869775, 734.3709175940857,
        801.9079286827169, 869.5653254388006, 937.3412478868744, 1005.2338947900839,
        1073.2415236501831, 1141.3624507075338, 1209.5950509411064, 1277.937758068479,
        1346.3890645458384, 1414.9475215679788, 1483.611739068303, 1552.3803857188218,
        1621.2521889301543, 1690.9886837735994, 1760.8077527361513, 1830.6368818882834,
        1900.5199860107073, 1970.5351215759783, 2040.8171152072134, 2111.1442587534093,
        2181.5839850773964, 2252.0432530926782, 2322.650038092568, 2393.1014734917753,
        2463.7310950335905, 2534.572001191695, 2605.5117240088694, 2676.469089363365,
        2747.535619154702, 2818.6967285506535, 2889.8722772843125, 2961.1666625659914,
        3032.4454694767155, 3103.8243779029754, 3175.2506428500924, 3246.8022290731933,
        3318.36103302869, 3389.9117658989844, 3461.5819979065623, 3533.4244726478323,
        3605.4496625313304, 3677.4366182607464, 3749.376756095155, 3821.389363648393,
        3893.6140893993083, 3965.9157178117293, 4038.3149675960385, 4110.888580746641,
        4183.403494996277, 4255.979668758947, 4328.678442752635, 4401.527914068221,
        4474.389810860523, 4547.285089265165, 4620.304494162832, 4693.361398875915,
        4766.48569780326, 4839.721951642775, 4913.066159747555, 4986.475798963366,
        5059.994293022372, 5133.609853715547, 5207.403857118294, 5281.399276616673,
        5355.465316758963, 5429.518092936405, 5503.700177842656, 5578.005699221327,
        5652.5302568256, 5727.3457788292835, 5802.248270278779, 5877.303809025915,
        5952.483066802424, 6027.904196278731, 6103.496320597117, 6179.167385474734,
        6255.07177539326, 6331.0816982846445, 6407.4643651968645, 6484.033301727959,
        6560.7470884354025, 6637.468954200861, 6714.4806812878805, 6791.724623921809,
        6869.130842154905, 6946.707770665279, 7024.487884979157, 7102.476324672041,
        7180.691006832363, 7259.142723379674, 7337.709432401869, 7416.501335363176,
        7495.415876094009, 7574.519814317005, 7653.970416787804, 7733.592234543872,
        7813.447501435828, 7893.524257942899, 7973.737070538293, 8054.0579911097475,
        8134.570845177595, 8215.335813380567, 8296.197976470403, 8377.38519458674,
        8458.750631590936, 8540.177097835318, 8621.784965288045, 8703.695959407572,
        8785.790815454666, 8867.954878616116, 8950.329297813272, 9032.844196957294,
        9115.595122538407, 9198.578272279865, 9281.740891202666, 9365.087055123,
        9448.809490484813, 9532.57228784587, 9616.58866773912, 9700.812340262062,
        9785.218828877127, 9869.776138771273, 9954.48837054387,
    ]

    private func energy(
        _ remainingAh: Double,
        capacityAh: Double = 134,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Double {
        try XCTUnwrap(AndroidEnergyCurve.remainingEnergyWh(
            remainingAh: remainingAh, capacityAh: capacityAh
        ), file: file, line: line)
    }

    private func legacyEnergy(_ ah: Double, capacityAh: Double) -> Double {
        let x = ah / capacityAh
        return ah * (66.0 + 9.8679 * x - 7.7636 * x * x + 5.8888 * x * x * x)
    }

    func testVersionAndSourceIdentifyReadOnlyAndroidSeed() {
        XCTAssertEqual(AndroidEnergyCurve.version, "d1-ah-seed-20260909-v1")
        XCTAssertTrue(AndroidEnergyCurve.source.contains("BatteryEnergySeedCurve.kt"))
        XCTAssertTrue(AndroidEnergyCurve.source.contains("BatteryEnergyCalibration.kt seedEnergy"))
        XCTAssertTrue(AndroidEnergyCurve.source.contains("not learned"))
    }

    func testEveryIntegerNodeMatchesPythonGoldenReference() throws {
        XCTAssertEqual(integerEnergyWh.count, 135)
        for ah in 0...134 {
            XCTAssertEqual(try energy(Double(ah)), integerEnergyWh[ah], accuracy: 1e-8, "Ah=\(ah)")
        }
    }

    func testFractionalNodesMatchPythonGoldenReference() throws {
        let cases: [(Double, Double)] = [
            (0.25, 16.504595819108662),
            (12.345, 825.2362239380972),
            (23.9, 1614.3604016188954),
            (23.999999, 1621.2521200071824),
            (24.000001, 1621.2522586666491),
            (50.25, 3479.54261659188),
            (100.37, 7209.718141954869),
            (133.999999, 9954.488285831638),
        ]
        for (ah, expectedWh) in cases {
            XCTAssertEqual(try energy(ah), expectedWh, accuracy: 1e-8, "Ah=\(ah)")
        }
    }

    func testEverySupportedBinIntegratesFractionsWithoutInterpolatingAcrossBins() throws {
        for bin in 24..<134 {
            let lower = integerEnergyWh[bin]
            let whPerAh = integerEnergyWh[bin + 1] - lower
            for fraction in [0.000001, 0.25, 0.37, 0.5, 0.75, 0.999999] {
                XCTAssertEqual(try energy(Double(bin) + fraction), lower + fraction * whPerAh,
                               accuracy: 1e-8, "bin=\(bin), fraction=\(fraction)")
            }
        }
    }

    func testUnobservedTailUsesLegacyIntegralNotFirstTableCoefficient() throws {
        for quarter in 0...96 {
            let ah = Double(quarter) / 4
            XCTAssertEqual(try energy(ah), legacyEnergy(ah, capacityAh: 134), accuracy: 1e-10)
        }
        XCTAssertEqual(try energy(12.345), legacyEnergy(12.345, capacityAh: 134), accuracy: 1e-10)
    }

    func testEndpointsAndJoinAreContinuous() throws {
        XCTAssertEqual(try energy(0), 0)
        XCTAssertEqual(try energy(-0.0), 0)
        XCTAssertEqual(try energy(24), integerEnergyWh[24], accuracy: 1e-8)
        XCTAssertEqual(try energy(134), integerEnergyWh[134], accuracy: 1e-8)
        for ah in [Double(24.0).nextDown, Double(24.0).nextUp] {
            XCTAssertEqual(try energy(ah), integerEnergyWh[24], accuracy: 1e-8)
        }
        XCTAssertEqual(try energy(Double(134.0).nextDown), integerEnergyWh[134], accuracy: 1e-8)
        XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: Double(134.0).nextUp, capacityAh: 134))
    }

    func testCapacityToleranceSelects134CurveWithoutExtrapolatingOrRelaxingInputBounds() throws {
        let lower = 134.0 - 0.000001
        let upper = 134.0 + 0.000001
        for capacity in [lower, 133.9999995, 134.0, 134.0000005, upper] {
            XCTAssertEqual(try energy(50.25, capacityAh: capacity), try energy(50.25), accuracy: 0)
            XCTAssertNotNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: capacity, capacityAh: capacity))
            XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: capacity.nextUp, capacityAh: capacity))
        }
        for capacity in [134.0000005, upper] {
            XCTAssertEqual(try energy(capacity, capacityAh: capacity), try energy(134), accuracy: 0)
        }
        XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 134, capacityAh: lower))
        for capacity in [lower.nextDown, upper.nextUp] {
            XCTAssertEqual(try energy(50.25, capacityAh: capacity),
                           legacyEnergy(50.25, capacityAh: capacity), accuracy: 1e-10)
            XCTAssertGreaterThan(abs(try energy(50.25, capacityAh: capacity) - energy(50.25)), 1)
        }
    }

    func testOtherCapacitiesUseTheirOwnLegacyPolynomialNeverScaled134Table() throws {
        for capacity in [0.000001, 0.5, 1.0, 24.0, 100.0, 133.0, 133.999998, 134.000002, 135.0, 200.0, 10_000.0] {
            for fraction in [0.0, 0.001, 0.125, 0.5, 0.625, 0.999, 1.0] {
                let ah = capacity * fraction
                XCTAssertEqual(try energy(ah, capacityAh: capacity),
                               legacyEnergy(ah, capacityAh: capacity), accuracy: 1e-8)
            }
        }
        let capacity = 100.0
        let ah = 50.0
        let incorrectlyScaledTable = try energy(134 * ah / capacity) * capacity / 134
        XCTAssertGreaterThan(abs(try energy(ah, capacityAh: capacity) - incorrectlyScaledTable), 1)
    }

    func test134CurveQuarterAhIncrementsStayInsideInclusive66To86WhPerAhBounds() throws {
        var previous = try energy(0)
        for step in 1...536 {
            let ah = Double(step) / 4
            let current = try energy(ah)
            let whPerAh = (current - previous) * 4
            XCTAssertTrue(current.isFinite)
            XCTAssertGreaterThan(current, previous)
            XCTAssertGreaterThanOrEqual(whPerAh, 66 - 1e-7)
            XCTAssertLessThanOrEqual(whPerAh, 86 + 1e-7)
            previous = current
        }
    }

    func testAllValidEnergyStaysInsideInclusiveAndroidEnvelope() throws {
        for capacity in [0.000001, 1.0, 100.0, 133.9999995, 134.0, 134.0000005, 200.0, 10_000.0] {
            for step in 0...536 {
                let ah = capacity * (Double(step) / 536)
                let wh = try energy(ah, capacityAh: capacity)
                XCTAssertTrue(wh.isFinite)
                XCTAssertGreaterThanOrEqual(wh, 66 * ah)
                XCTAssertLessThanOrEqual(wh, 86 * ah)
            }
            XCTAssertEqual(try energy(0, capacityAh: capacity), 66 * 0)
            XCTAssertEqual(try energy(0, capacityAh: capacity), 86 * 0)
        }
        // 极小正数在 Double 精度下落在 66Wh/Ah 下边界，仍是合法容量/能量。
        XCTAssertEqual(try energy(Double.leastNonzeroMagnitude, capacityAh: 100),
                       66 * Double.leastNonzeroMagnitude)
    }

    func testInvalidInputsReturnNilRatherThanClampingOrFabricatingEnergy() {
        for capacity in [Double.nan, .infinity, -.infinity, -1, -0.0, 0, 10_000.0.nextUp] {
            XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 0, capacityAh: capacity))
        }
        for ah in [Double.nan, .infinity, -.infinity, -1, -Double.leastNonzeroMagnitude, Double(134.0).nextUp] {
            XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: ah, capacityAh: 134))
        }
        XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: Double(100.0).nextUp, capacityAh: 100))
        XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: 10_000.0.nextUp, capacityAh: 10_000))
        XCTAssertNil(AndroidEnergyCurve.remainingEnergyWh(remainingAh: .nan, capacityAh: .nan))
    }
}
