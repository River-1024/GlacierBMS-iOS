import Foundation
import XCTest
@testable import ANTuRideDomain

final class ControllerModelsTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_792_000_000.125)

    func testControllerSampleRoundTripsThroughCodable() throws {
        let sample = ControllerSample(
            timestamp: timestamp,
            voltage: 72.3,
            current: -12.5,
            rpm: 1250,
            speed: 31.25,
            throttle: 3.3,
            brake: 0.4
        )

        let decoded = try JSONDecoder().decode(
            ControllerSample.self,
            from: JSONEncoder().encode(sample)
        )
        XCTAssertEqual(decoded, sample)
    }

    func testSessionAppendsChronologicallyAndCSVUsesStableHeader() {
        let session = ControllerRecordSession()
        let first = sample(at: timestamp)
        let duplicate = sample(at: timestamp, voltage: 99)
        let second = sample(at: timestamp.addingTimeInterval(1), voltage: 73)

        XCTAssertTrue(session.append(first))
        XCTAssertFalse(session.append(duplicate))
        XCTAssertTrue(session.append(second))
        XCTAssertEqual(session.finish(), [first, second])
        XCTAssertEqual(session.count, 2)
        XCTAssertTrue(session.isFinished)

        XCTAssertEqual(
            session.exportCSV(),
            "timestamp,voltage,current,rpm,speed,throttle,brake\n" +
            "2026-10-14T17:46:40.125Z,72.3,-12.5,1250,31.25,3.3,0.4\n" +
            "2026-10-14T17:46:41.125Z,73.0,-12.5,1250,31.25,3.3,0.4\n"
        )
    }

    func testFinishedSessionRejectsFurtherSamples() {
        let session = ControllerRecordSession()
        session.finish()

        XCTAssertFalse(session.append(sample(at: timestamp)))
        XCTAssertEqual(session.count, 0)
    }

    func testAssemblerHandlesFragmentsNoiseMultipleFramesAndBounds() {
        let first = frame(dataLength: 3, fill: 0x10)
        let second = frame(dataLength: 5, fill: 0x20)
        let assembler = MotorControllerFrameAssembler(maximumFrameLength: 32)

        XCTAssertTrue(assembler.append(Data([0x00, 0xFF]) + Data(first.prefix(4))).isEmpty)
        XCTAssertEqual(assembler.append(Data(first.dropFirst(4)) + second), [first, second])

        let malformed = Data([0xA8, 0x02, 0x01, 0x24, 0x01, 0xFF])
        XCTAssertTrue(assembler.append(malformed).isEmpty)
        XCTAssertLessThanOrEqual(assembler.pendingByteCount, 5)
    }

    func testSessionRejectsInvalidAndOutOfOrderTimestamps() {
        let session = ControllerRecordSession()
        for seconds in [Double.nan, .infinity, -.infinity, -62_135_596_801, 253_402_300_800] {
            XCTAssertFalse(session.append(sample(at: Date(timeIntervalSince1970: seconds))))
        }
        XCTAssertEqual(session.count, 0)
        XCTAssertTrue(session.append(sample(at: timestamp)))
        XCTAssertFalse(session.append(sample(at: timestamp.addingTimeInterval(-1))))
        XCTAssertFalse(session.append(sample(at: timestamp)))
        XCTAssertTrue(session.append(sample(at: timestamp.addingTimeInterval(1))))
        XCTAssertFalse(session.append(sample(at: timestamp)))
        XCTAssertEqual(session.finish().map(\.timestamp), [timestamp, timestamp.addingTimeInterval(1)])
    }

    func testNonFiniteMeasurementsExportAsEmptyCellsWithoutDroppingSample() {
        let session = ControllerRecordSession()
        XCTAssertTrue(session.append(ControllerSample(
            timestamp: timestamp, voltage: .nan, current: .infinity, rpm: 1250,
            speed: -.infinity, throttle: .nan, brake: .infinity
        )))
        XCTAssertEqual(session.exportCSV(), ControllerRecordSession.csvHeader + "\n" +
                       "2026-10-14T17:46:40.125Z,,,1250,,,\n")
        XCTAssertEqual(session.count, 1)
        XCTAssertEqual(session.exportCSV().split(separator: "\n")[1]
            .split(separator: ",", omittingEmptySubsequences: false).count, 7)
    }

    func testEmptySessionExportsHeaderAndFinishIsIdempotent() {
        let session = ControllerRecordSession()
        XCTAssertEqual(session.exportCSV(), ControllerRecordSession.csvHeader + "\n")
        XCTAssertEqual(session.finish(), [])
        XCTAssertEqual(session.finish(), [])
    }

    func testQueryCommandMatchesAndroidGoldenAndReturnsIndependentData() {
        let expected = Data([0xA8, 0x02, 0x01, 0x24, 0x01, 0x1F, 0x3E, 0x4F])
        XCTAssertEqual(MotorControllerProtocol.realtimeMonitorCommand(), expected)
        var changed = MotorControllerProtocol.realtimeMonitorCommand()
        changed[0] = 0
        changed[3] = 0x23
        XCTAssertEqual(MotorControllerProtocol.realtimeMonitorCommand(), expected)
    }

    func test37And39ByteFramesAtEveryFragmentBoundary() {
        for length in [0x1D, 0x1F] {
            let response = frame(dataLength: length, fill: 0x0D)
            XCTAssertEqual(response.count, length == 0x1D ? 37 : 39)
            for split in 1..<response.count {
                let assembler = MotorControllerFrameAssembler()
                XCTAssertTrue(assembler.append(Data(response.prefix(split))).isEmpty)
                XCTAssertEqual(assembler.pendingByteCount, split)
                XCTAssertTrue(assembler.append(Data()).isEmpty)
                XCTAssertEqual(assembler.pendingByteCount, split)
                XCTAssertEqual(assembler.append(Data(response.dropFirst(split))), [response])
                XCTAssertEqual(assembler.pendingByteCount, 0)
            }
        }
    }

    func testOneByteFragmentsNoiseAndMultipleFramesDoNotUse0DAsTail() {
        let short = frame(dataLength: 0x1D, fill: 0x0D)
        let long = frame(dataLength: 0x1F, fill: 0x0D)
        let noise = Data([0x0D, 0xFF, 0x00, 0xA8])
        let assembler = MotorControllerFrameAssembler()
        var frames: [Data] = []
        for byte in noise + short + noise + long {
            frames += assembler.append(Data([byte]))
        }
        XCTAssertEqual(frames, [short, long])
        XCTAssertEqual(assembler.pendingByteCount, 0)
        XCTAssertEqual(assembler.append(noise + short + long), [short, long])
    }

    func testEveryIncompleteFrameStaysPendingAndResetDiscardsIt() {
        for length in [0x1D, 0x1F] {
            let response = frame(dataLength: length, fill: 0x0D)
            for count in 1..<response.count {
                let assembler = MotorControllerFrameAssembler()
                XCTAssertTrue(assembler.append(Data(response.prefix(count))).isEmpty)
                XCTAssertEqual(assembler.pendingByteCount, count)
                assembler.reset()
                XCTAssertEqual(assembler.pendingByteCount, 0)
                XCTAssertEqual(assembler.append(response), [response])
            }
        }
    }

    func testAssemblerLeavesUnsupportedLENForSemanticParser() {
        let response = frame(dataLength: 0x1E, fill: 0x0D)
        let assembler = MotorControllerFrameAssembler()
        XCTAssertEqual(assembler.append(response), [response])
        XCTAssertEqual(MotorControllerProtocol.parseRealtimeResponse(response), .invalid(.lengthMismatch))
        XCTAssertTrue(assembler.append(Data(repeating: 0x0D, count: 1024)).isEmpty)
        XCTAssertLessThanOrEqual(assembler.pendingByteCount, 5)
        let zeroLength = Data([0xA8, 0x02, 0x01, 0x24, 0x01, 0])
        XCTAssertEqual(assembler.append(zeroLength + response), [response])
    }

    func testReal37ByteCaptureParsesAndHasNoInventedBrakeValue() throws {
        let capture = Data([
            0xA8, 0x01, 0x02, 0x24, 0x01, 0x1D, 0xD0, 0x02, 0, 0, 0, 0,
            0x50, 0x65, 0, 0, 0x56, 0, 0x02, 0x23, 0, 0, 0, 0xBD, 0x03,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0A, 0x16
        ])
        XCTAssertEqual(capture.count, 37)
        let assembler = MotorControllerFrameAssembler()
        XCTAssertTrue(assembler.append(Data(capture.prefix(20))).isEmpty)
        let assembled = try XCTUnwrap(assembler.append(Data(capture.dropFirst(20))).first)
        let telemetry = try validTelemetry(assembled)
        XCTAssertEqual(telemetry.controllerVoltageV, 72)
        XCTAssertEqual(telemetry.busCurrentA, 0)
        XCTAssertEqual(telemetry.rpm, 0)
        XCTAssertEqual(telemetry.controllerTemperatureC, 25)
        XCTAssertEqual(telemetry.motorTemperatureC, 46)
        XCTAssertEqual(telemetry.throttleVoltageV, 0.86)
        XCTAssertEqual(telemetry.gear, 2)
        XCTAssertEqual(telemetry.controllerStateBits, 0x23)
        XCTAssertEqual(telemetry.portStatusBits, 0x03BD)
        XCTAssertEqual(telemetry.faultSummary, "无故障")
        XCTAssertNil(telemetry.linearBrakeVoltageV)
    }

    func test39ByteResponseDecodesEveryFieldAndSignedLittleEndianValues() throws {
        var region = [UInt8](repeating: 0, count: 31)
        func word(_ offset: Int, _ value: Int) {
            region[offset] = UInt8(truncatingIfNeeded: value)
            region[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        word(0, -100)
        word(2, -125)
        word(4, -1000)
        region[6] = 80
        region[7] = 95
        word(8, 0xFEDC)
        word(10, 0x010D) // 0x0D inside the payload is not a terminator.
        region[12] = 0x32
        word(13, 0x1234)
        word(15, 0x8001)
        word(17, 0x5678)
        word(19, -250)
        word(21, 123)
        word(23, -32768)
        word(25, 32767)
        word(27, 0x9ABC)
        word(29, 450)
        let response = Data([0, 0x0D, 0xFF, 0x24, 0x01, 0x1F] + region + [0, 0])
        let telemetry = try validTelemetry(response)
        XCTAssertEqual(telemetry.controllerVoltageV, -10)
        XCTAssertEqual(telemetry.busCurrentA, -12.5)
        XCTAssertEqual(telemetry.rpm, -1000)
        XCTAssertEqual(telemetry.controllerTemperatureC, 25)
        XCTAssertEqual(telemetry.motorTemperatureC, 40)
        XCTAssertEqual(telemetry.phasePeakCurrentA, Double(0xFEDC) / 10)
        XCTAssertEqual(telemetry.throttleVoltageV, 2.69)
        XCTAssertEqual(telemetry.runStateCode, 3)
        XCTAssertEqual(telemetry.runStateText, "运行")
        XCTAssertEqual(telemetry.gear, 2)
        XCTAssertEqual(telemetry.controllerStateBits, 0x1234)
        XCTAssertEqual(telemetry.faultBits, 0x8001)
        XCTAssertEqual(telemetry.faultSummary, "霍尔故障、未知故障位15")
        XCTAssertEqual(telemetry.portStatusBits, 0x5678)
        XCTAssertEqual(telemetry.givenIqA, -25)
        XCTAssertEqual(telemetry.feedbackIqA, 12.3)
        XCTAssertEqual(telemetry.givenIdA, -3276.8)
        XCTAssertEqual(telemetry.fieldWeakeningA, 3276.7)
        XCTAssertEqual(telemetry.historyFaultBits, 0x9ABC)
        XCTAssertEqual(try XCTUnwrap(telemetry.linearBrakeVoltageV), 4.5)
        XCTAssertEqual(MotorControllerFrameAssembler().append(response), [response])
    }

    func testParserRejectsShortWrongCommandAddressLENAndExtraBytes() {
        for length in [0x1D, 0x1F] {
            let response = frame(dataLength: length, fill: 0)
            for count in 0..<response.count {
                XCTAssertEqual(MotorControllerProtocol.parseRealtimeResponse(Data(response.prefix(count))),
                               .invalid(.frameTooShort))
            }
            XCTAssertEqual(MotorControllerProtocol.parseRealtimeResponse(response + Data([0])),
                           .invalid(.frameLengthMismatch))
        }
        var wrong = frame(dataLength: 0x1F, fill: 0)
        wrong[3] = 0x23
        XCTAssertEqual(MotorControllerProtocol.parseRealtimeResponse(wrong), .invalid(.commandMismatch))
        wrong[3] = 0x24
        wrong[4] = 2
        XCTAssertEqual(MotorControllerProtocol.parseRealtimeResponse(wrong), .invalid(.addressMismatch))
        wrong[4] = 1
        for length in [UInt8(0), 0x1B, 0x1C, 0x1E, 0x20, 0xFF] {
            wrong[5] = length
            XCTAssertEqual(MotorControllerProtocol.parseRealtimeResponse(wrong), .invalid(.lengthMismatch))
        }
    }

    func testParserAcceptsNonzeroDataSliceIndexAndUnknownRunState() throws {
        var response = frame(dataLength: 0x1D, fill: 0)
        response[6 + 12] = 0xF1
        let padded = Data([0xFF]) + response
        let slice = padded.dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        let telemetry = try validTelemetry(slice)
        XCTAssertEqual(telemetry.runStateText, "未知")
        XCTAssertEqual(telemetry.gear, 1)
    }

    private func validTelemetry(_ response: Data, file: StaticString = #filePath, line: UInt = #line) throws
        -> MotorControllerTelemetry {
        guard case .valid(let telemetry) = MotorControllerProtocol.parseRealtimeResponse(response) else {
            XCTFail("Expected valid real-time telemetry", file: file, line: line)
            throw NSError(domain: "ControllerModelsTests", code: 1)
        }
        return telemetry
    }

    private func sample(at date: Date, voltage: Double = 72.3) -> ControllerSample {
        ControllerSample(
            timestamp: date,
            voltage: voltage,
            current: -12.5,
            rpm: 1250,
            speed: 31.25,
            throttle: 3.3,
            brake: 0.4
        )
    }

    private func frame(dataLength: Int, fill: UInt8) -> Data {
        Data([0xA8, 0x02, 0x01, 0x24, 0x01, UInt8(dataLength)]) +
            Data(repeating: fill, count: dataLength) +
            Data([0x00, 0x00])
    }
}
