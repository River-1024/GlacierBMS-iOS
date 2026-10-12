import ANTuRideDomain
import Foundation
import XCTest
@testable import ANTuRide

final class DeviceParameterReadoutTests: XCTestCase {
    func testMissingBatteryValuesDoNotBecomeZeroOrClosedMOS() {
        for metric in ParameterCatalog.metrics(for: .battery) {
            let result = DeviceParameterReadout.read(battery: nil, metricID: metric.id)
            XCTAssertEqual(result.title, metric.title, metric.id)
            XCTAssertEqual(result.value, "--", metric.id)
            XCTAssertEqual(result.unit, "", metric.id)
            XCTAssertNil(result.detail, metric.id)
        }
    }

    func testBatteryValidZeroAndOptionalMissingFieldsStayDistinct() {
        let snapshot = battery()
        for id in ["bms_current", "bms_soc", "bms_remaining", "bms_mos_temperature",
                   "bms_balancer_temperature", "bms_unparsed_bytes"] {
            XCTAssertNotEqual(DeviceParameterReadout.read(battery: snapshot, metricID: id).value, "--", id)
        }
        for id in ["bms_soh", "bms_power", "bms_runtime", "bms_diff", "bms_balance_status",
                   "bms_balance_mask", "bms_status_code", "bms_charge_mos", "bms_discharge_mos"] {
            XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: id).value, "--", id)
        }
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_current").value, "0.0")
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_current").unit, "A")
    }

    func testBatteryScalarCatalogMappings() {
        let snapshot = BmsSnapshot(totalVoltage: 80.25, current: -2.5, soc: 0, capacityAh: 100.5,
            remainingAh: 0, temperatures: [-10, 0, 60], mosTemperature: 75, balancerTemperature: 0,
            cellVoltagesMillivolts: [4000, 3900], soh: 0, power: 0, runtimeSeconds: 3661,
            voltageDiffMillivolts: 100, chargeMOSOn: true, dischargeMOSOn: false, balanceStatus: 0,
            balanceMask: 0, statusCode: 0, statusText: "静止", frameLength: 140, unparsedBytes: 0)
        let expected = [
            "bms_voltage": "80.25", "bms_current": "-2.5", "bms_power": "0", "bms_soc": "0",
            "bms_remaining": "0.0", "bms_capacity": "100.5", "bms_soh": "0", "bms_cell_count": "2",
            "bms_cell_max": "4000", "bms_cell_min": "3900", "bms_diff": "100",
            "bms_temperature": "60", "bms_temperature_min": "-10", "bms_mos_temperature": "75",
            "bms_balancer_temperature": "0", "bms_status": "静止", "bms_charge_mos": "开启",
            "bms_discharge_mos": "关闭", "bms_balance_status": "0", "bms_balance_mask": "0x0",
            "bms_runtime": "1h01m", "bms_status_code": "0", "bms_frame_length": "140", "bms_unparsed_bytes": "0"
        ]
        let scalars = ParameterCatalog.metrics(for: .battery).filter { !ParameterCatalog.isChannel($0.id) }
        XCTAssertEqual(Set(expected.keys), Set(scalars.map(\.id)))
        for metric in scalars {
            let result = DeviceParameterReadout.read(battery: snapshot, metricID: metric.id)
            XCTAssertEqual(result.value, expected[metric.id], metric.id)
            XCTAssertEqual(result.unit, metric.unit, metric.id)
        }
    }

    func testCallerSuppliesNilForExpiredBatterySnapshot() {
        let snapshot = battery()
        let freshness = BmsFreshnessEvaluator().evaluate(snapshot: snapshot,
            now: snapshot.receivedAt.addingTimeInterval(6))
        XCTAssertEqual(freshness.level, .stale)
        let current = freshness.level == .fresh ? snapshot : nil
        XCTAssertEqual(DeviceParameterReadout.read(battery: current, metricID: "bms_voltage").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(battery: current, metricID: "bms_cell_voltage_1").value, "--")
    }

    func testCellAndProbeNumbersUseOneBasedRealChannels() {
        let cells = (1...64).map { 3000 + $0 }
        let probes = (1...16).map { $0 - 10 }
        let snapshot = battery(cells: cells, temperatures: probes)
        for channel in 1...64 {
            let result = DeviceParameterReadout.read(battery: snapshot, metricID: "bms_cell_voltage_\(channel)")
            XCTAssertEqual(result.title, "单体 \(channel)")
            XCTAssertEqual(result.value, String(cells[channel - 1]))
            XCTAssertEqual(result.unit, "mV")
        }
        for channel in 1...16 {
            let result = DeviceParameterReadout.read(battery: snapshot, metricID: "bms_probe_temperature_\(channel)")
            XCTAssertEqual(result.title, "探头 \(channel)")
            XCTAssertEqual(result.value, String(probes[channel - 1]))
            XCTAssertEqual(result.unit, "℃")
        }
    }

    func testReducedAndInvalidChannelsNeverIndexOutsideArrays() {
        let snapshot = battery(cells: [4100], temperatures: [0])
        for id in ["bms_cell_voltage_2", "bms_cell_voltage_64", "bms_cell_voltage_0", "bms_cell_voltage_-1",
                   "bms_cell_voltage_65", "bms_probe_temperature_2", "bms_probe_temperature_16",
                   "bms_probe_temperature_17", "bms_probe_temperature_bad"] {
            let result = DeviceParameterReadout.read(battery: snapshot, metricID: id)
            XCTAssertEqual(result.value, "--", id)
            XCTAssertNil(result.detail, id)
        }
        let empty = battery(cells: [], temperatures: [])
        XCTAssertEqual(DeviceParameterReadout.read(battery: empty, metricID: "bms_cell_voltage_1").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(battery: empty, metricID: "bms_probe_temperature_1").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(battery: empty, metricID: "bms_temperature").value, "--")
    }

    func testCellExtremaMarkAllActualTies() {
        let snapshot = battery(cells: [4200, 4200, 4000, 4000, 4100])
        for channel in [1, 2] {
            XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_cell_voltage_\(channel)").detail, "最高")
        }
        for channel in [3, 4] {
            XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_cell_voltage_\(channel)").detail, "最低")
        }
        XCTAssertNil(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_cell_voltage_5").detail)
        XCTAssertEqual(DeviceParameterReadout.read(battery: battery(cells: [4000, 4000]),
                                                   metricID: "bms_cell_voltage_2").detail, "最高 / 最低")
    }

    func testTemperatureUsesActualProbeExtremaNotDashboardSelection() {
        let snapshot = battery(temperatures: [-20, 0, 80])
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_temperature").title, "最高探头温度")
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_temperature").value, "80")
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_temperature_min").value, "-20")
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_probe_temperature_2").value, "0")
    }

    func testEachMOSPreservesUnknownOnAndOffIndependently() {
        let snapshot = battery(chargeMOSOn: true, dischargeMOSOn: nil)
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_charge_mos").value, "开启")
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_discharge_mos").value, "--")
        let inverse = battery(chargeMOSOn: nil, dischargeMOSOn: false)
        XCTAssertEqual(DeviceParameterReadout.read(battery: inverse, metricID: "bms_charge_mos").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(battery: inverse, metricID: "bms_discharge_mos").value, "关闭")
    }

    func testNonFiniteBatteryValuesAreUnavailable() {
        let snapshot = battery(totalVoltage: .infinity, power: .nan)
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_voltage").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(battery: snapshot, metricID: "bms_power").value, "--")
    }

    func testMissingControllerValuesAreUnavailableWithPageTitles() {
        for metric in ParameterCatalog.metrics(for: .controller) {
            let result = DeviceParameterReadout.read(controller: nil, metricID: metric.id)
            XCTAssertEqual(result.title, metric.title, metric.id)
            XCTAssertEqual(result.value, "--", metric.id)
            XCTAssertEqual(result.unit, "", metric.id)
        }
    }

    func testControllerZeroIsValidButOptionalBrakeRemainsUnavailable() throws {
        let telemetry = try controller()
        let result = DeviceParameterReadout.read(controller: telemetry, metricID: "controller_bus_current")
        XCTAssertEqual(result.value, "0.00")
        XCTAssertEqual(result.unit, "A")
        XCTAssertEqual(DeviceParameterReadout.read(controller: telemetry, metricID: "controller_rpm").value, "0")
        XCTAssertEqual(DeviceParameterReadout.read(controller: telemetry, metricID: "controller_fault").value, "无故障")
        XCTAssertEqual(DeviceParameterReadout.read(controller: telemetry, metricID: "controller_linear_brake_voltage").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(controller: try controller(overrides: ["linearBrakeVoltageV": 0]),
            metricID: "controller_linear_brake_voltage").value, "0.00")
    }

    func testControllerCatalogMappingsUseTheirActualFields() throws {
        let telemetry = try controller(overrides: ["controllerVoltageV": 72.3, "busCurrentA": -12.5,
            "rpm": -1250, "controllerTemperatureC": 25, "motorTemperatureC": 40,
            "phasePeakCurrentA": 45.6, "throttleVoltageV": 3.3, "runStateCode": 3, "gear": 10,
            "controllerStateBits": 17, "faultBits": 2, "portStatusBits": 957,
            "givenIqA": -25, "feedbackIqA": 12.3, "givenIdA": -10, "fieldWeakeningA": 8.5,
            "historyFaultBits": 6, "linearBrakeVoltageV": 4.5])
        let expected = [
            "controller_voltage": "72.30", "controller_bus_current": "-12.50", "controller_phase_current": "45.60",
            "controller_rpm": "-1250", "controller_temperature": "25", "controller_motor_temperature": "40",
            "controller_throttle_voltage": "3.30", "controller_linear_brake_voltage": "4.50",
            "controller_run_state": "运行", "controller_gear": "A", "controller_fault": "硬件过流",
            "controller_given_iq": "-25.00", "controller_feedback_iq": "12.30", "controller_given_id": "-10.00",
            "controller_field_weakening": "8.50", "controller_state_bits": "17", "controller_current_fault_bits": "2",
            "controller_port_bits": "957", "controller_history_fault_bits": "6",
            "controller_notify_count": "7", "controller_frame_count": "5", "controller_pending_bytes": "3"
        ]
        let metrics = ParameterCatalog.metrics(for: .controller)
        XCTAssertEqual(Set(expected.keys), Set(metrics.map(\.id)))
        for metric in metrics {
            let result = DeviceParameterReadout.read(controller: telemetry, metricID: metric.id,
                notificationCount: 7, frameCount: 5, pendingByteCount: 3)
            XCTAssertEqual(result.value, expected[metric.id], metric.id)
            XCTAssertEqual(result.unit, metric.unit, metric.id)
        }
    }

    func testExpiredControllerCanKeepHistoricalDiagnosticsButNotTelemetry() {
        let result = DeviceParameterReadout.read(controller: nil, metricID: "controller_notify_count", notificationCount: 0)
        XCTAssertEqual(result.value, "0")
        XCTAssertTrue(result.detail?.contains("不代表遥测有效") == true)
        XCTAssertEqual(DeviceParameterReadout.read(controller: nil, metricID: "controller_frame_count", frameCount: 12).value, "12")
        XCTAssertEqual(DeviceParameterReadout.read(controller: nil, metricID: "controller_pending_bytes", pendingByteCount: 3).value, "3")
        XCTAssertEqual(DeviceParameterReadout.read(controller: nil, metricID: "controller_current_fault_bits").value, "--")
        XCTAssertEqual(DeviceParameterReadout.read(controller: nil, metricID: "controller_voltage").value, "--")
    }

    func testHomeMOSPartialUnknownDoesNotBecomeClosed() {
        let unknown = HomeParameterReadout.read(metricId: "bms_mos_status", snapshot: battery())
        XCTAssertEqual(unknown.value, "未知")
        let chargeUnknown = HomeParameterReadout.read(metricId: "bms_mos_status",
            snapshot: battery(chargeMOSOn: nil, dischargeMOSOn: false))
        XCTAssertNotEqual(chargeUnknown.value, "充电关 · 放电关")
        XCTAssertTrue(chargeUnknown.value.contains("未知") || chargeUnknown.value.contains("--"))
        XCTAssertTrue(chargeUnknown.value.contains("放电关"))
        let dischargeUnknown = HomeParameterReadout.read(metricId: "bms_mos_status",
            snapshot: battery(chargeMOSOn: false, dischargeMOSOn: nil))
        XCTAssertNotEqual(dischargeUnknown.value, "充电关 · 放电关")
        XCTAssertTrue(dischargeUnknown.value.contains("未知") || dischargeUnknown.value.contains("--"))
        XCTAssertTrue(dischargeUnknown.value.contains("充电关"))
    }

    func testNonFiniteControllerFieldsAreUnavailable() throws {
        let telemetry = try controller(overrides: ["controllerVoltageV": "Infinity", "busCurrentA": "NaN",
                                                   "linearBrakeVoltageV": "-Infinity"])
        for id in ["controller_voltage", "controller_bus_current", "controller_linear_brake_voltage"] {
            let result = DeviceParameterReadout.read(controller: telemetry, metricID: id)
            XCTAssertEqual(result.value, "--", id)
            XCTAssertEqual(result.unit, "", id)
        }
    }

    private func battery(cells: [Int] = [4000], temperatures: [Int] = [0],
                         chargeMOSOn: Bool? = nil, dischargeMOSOn: Bool? = nil,
                         totalVoltage: Double = 80, power: Double? = nil) -> BmsSnapshot {
        BmsSnapshot(totalVoltage: totalVoltage, current: 0, soc: 0, capacityAh: 100, remainingAh: 0,
                    temperatures: temperatures, mosTemperature: 0, balancerTemperature: 0,
                    cellVoltagesMillivolts: cells, power: power,
                    chargeMOSOn: chargeMOSOn, dischargeMOSOn: dischargeMOSOn, frameLength: 140)
    }

    /// Codable fixture uses only domain data; no Bluetooth service/manager is constructed.
    private func controller(overrides: [String: Any] = [:]) throws -> MotorControllerTelemetry {
        var fields: [String: Any] = [
            "controllerVoltageV": 0, "busCurrentA": 0, "rpm": 0, "controllerTemperatureC": 0,
            "motorTemperatureC": 0, "phasePeakCurrentA": 0, "throttleVoltageV": 0, "runStateCode": 0,
            "gear": 0, "controllerStateBits": 0, "faultBits": 0, "portStatusBits": 0,
            "givenIqA": 0, "feedbackIqA": 0, "givenIdA": 0, "fieldWeakeningA": 0,
            "historyFaultBits": 0, "linearBrakeVoltageV": NSNull()
        ]
        fields.merge(overrides) { _, replacement in replacement }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(MotorControllerTelemetry.self,
            from: JSONSerialization.data(withJSONObject: fields))
    }
}
