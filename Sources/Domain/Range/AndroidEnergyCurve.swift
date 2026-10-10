import Foundation

/// Android 内置能量先验的只读移植；不采样、不学习、不保存校准记录。
/// 数据来自 BatteryEnergySeedCurve.kt（tools/range_seed/build_d1_seed.py 生成，
/// 溯源 docs/range-seed-20260909），仅代表 134Ah / 20 串来源电池。
/// 未观测的 0...24Ah 尾段保留 legacy 积分；不构成完整放电或实车精度认证。
public enum AndroidEnergyCurve {
    public static let version = "d1-ah-seed-20260909-v1"
    /// 134Ah 容量容差内使用原始表，其他容量使用 BatteryEnergyCalibration.seedEnergy 的 legacy 公式。
    public static let source = "Android BatteryEnergySeedCurve.kt / BatteryEnergyCalibration.kt seedEnergy (built-in seed, not learned)"

    private static let referenceCapacityAh = 134.0
    private static let firstSupportedAh = 24.0
    private static let capacityToleranceAh = 0.000001
    private static let whPerAh: [Double] = [
        69.736494843445, 69.819068962552, 69.829129152132, 69.883104122424, 70.015135565271,
        70.281993631235, 70.327143546196, 70.439726323987, 70.459268015282, 70.606784999890,
        70.451435399207, 70.629621541815, 70.840906158105, 70.939722817174, 70.957365354496,
        71.066529791337, 71.161109395951, 71.175548733659, 71.294385281679, 71.278806910724,
        71.378908426260, 71.426264947117, 71.551586223101, 71.558803955497, 71.550732870294,
        71.670232007578, 71.842474741270, 72.025189883498, 71.986955729416, 71.940137834409,
        72.012607553238, 72.224725750915, 72.301628412421, 72.399249784309, 72.573613150603,
        72.514914249636, 72.576173762670, 72.698773993688, 72.849471315586, 72.861896792301,
        72.895278404643, 73.019404897667, 73.056904713083, 73.124298927345, 73.236253839515,
        73.344208104779, 73.409639215812, 73.518494059006, 73.615560693174, 73.794003402747,
        73.995419498380, 74.066040142290, 74.052776177442, 74.182084906250, 74.305521378671,
        74.524557604274, 74.815522003683, 74.902491449496, 75.055538747136, 75.179257776509,
        75.421129476307, 75.592124318386, 75.671064877617, 75.904389918526, 76.009922891384,
        76.382666912220, 76.568936531095, 76.713786707443, 76.721865765459, 77.011727087019,
        77.243942633929, 77.406218233095, 77.576928510375, 77.780114313877, 77.988439692885,
        78.214682160322, 78.451716547311, 78.566709022195, 78.791902961306, 78.914540730834,
        79.103938222995, 79.450602470800, 79.621817756068, 79.855266891955, 80.076756507071,
        80.212812595394, 80.320920571455, 80.512854067848, 80.764968202972, 80.862163089836,
        81.187218116338, 81.365437004195, 81.426466244381, 81.607867452728, 81.910994119527,
        82.094856047093, 82.164063161450, 82.374419197156, 82.514899144023, 82.750925581112,
        82.983149741458, 83.162618922801, 83.346163920335, 83.722435361813, 83.762797361056,
        84.016379893252, 84.223672522940, 84.406488615065, 84.557309894147, 84.712231772597,
    ]

    /// 返回剩余能量（Wh）；非法输入返回 nil，不把超容量的输入静默夹紧。
    /// 与 Android 一致：容量须有限且在 (0, 10000]Ah，剩余 Ah 须有限且在 [0, capacityAh]。
    /// 仅 abs(capacityAh - 134) <= 1e-6 使用原表；不会按 SOC/容量缩放 134Ah 表。
    /// 此容差只选择曲线：表内 q 封顶于 134Ah，最终能量遵循 Android 的 66...86Wh/Ah 包络。
    public static func remainingEnergyWh(remainingAh: Double, capacityAh: Double) -> Double? {
        guard capacityAh.isFinite, capacityAh > 0, capacityAh <= 10_000,
              remainingAh.isFinite, remainingAh >= 0, remainingAh <= capacityAh else {
            return nil
        }

        let energy: Double
        if abs(capacityAh - referenceCapacityAh) <= capacityToleranceAh {
            energy = energyAt134Ah(remainingAh)
        } else {
            energy = legacyEnergy(remainingAh, capacityAh: capacityAh)
        }
        // 与 Android 无学习记录的 estimate 一致；包络以原始 remainingAh 而非表内 q 计算。
        return min(max(energy, 66.0 * remainingAh), 86.0 * remainingAh)
    }

    private static func energyAt134Ah(_ remainingAh: Double) -> Double {
        let q = min(remainingAh, referenceCapacityAh)
        var energy = legacyEnergy(min(q, firstSupportedAh), capacityAh: referenceCapacityAh)
        for (index, wh) in whPerAh.enumerated() {
            let lower = firstSupportedAh + Double(index)
            energy += min(max(q - lower, 0.0), 1.0) * wh
        }
        let end = firstSupportedAh + Double(whPerAh.count)
        if q > end {
            energy += legacyEnergy(q, capacityAh: referenceCapacityAh)
                - legacyEnergy(end, capacityAh: referenceCapacityAh)
        }
        return energy
    }

    private static func legacyEnergy(_ ah: Double, capacityAh: Double) -> Double {
        let x = ah / capacityAh
        return ah * (66.0 + 9.8679 * x - 7.7636 * x * x + 5.8888 * x * x * x)
    }
}
