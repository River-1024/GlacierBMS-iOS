import Foundation

public struct BmsSnapshot: Equatable, Sendable {
    public let receivedAt: Date
    public let totalVoltage: Double
    public let current: Double
    public let soc: Double
    public let capacityAh: Double
    public let remainingAh: Double
    public let temperatures: [Int]
    public let mosTemperature: Int
    public let balancerTemperature: Int
    public let cellVoltagesMillivolts: [Int]
    public let soh: Int?
    public let power: Double?
    public let runtimeSeconds: UInt32?
    public let voltageDiffMillivolts: Int?
    public let chargeMOSOn: Bool?
    public let dischargeMOSOn: Bool?
    public let balanceStatus: Int?
    public let balanceMask: UInt32?
    public let statusCode: Int?
    public let statusText: String
    public let frameLength: Int
    public let unparsedBytes: Int

    public init(
        receivedAt: Date = Date(),
        totalVoltage: Double,
        current: Double,
        soc: Double,
        capacityAh: Double,
        remainingAh: Double,
        temperatures: [Int],
        mosTemperature: Int,
        balancerTemperature: Int,
        cellVoltagesMillivolts: [Int],
        soh: Int? = nil,
        power: Double? = nil,
        runtimeSeconds: UInt32? = nil,
        voltageDiffMillivolts: Int? = nil,
        chargeMOSOn: Bool? = nil,
        dischargeMOSOn: Bool? = nil,
        balanceStatus: Int? = nil,
        balanceMask: UInt32? = nil,
        statusCode: Int? = nil,
        statusText: String = "未知",
        frameLength: Int = 0,
        unparsedBytes: Int = 0
    ) {
        self.receivedAt = receivedAt
        self.totalVoltage = totalVoltage
        self.current = current
        self.soc = soc
        self.capacityAh = capacityAh
        self.remainingAh = remainingAh
        self.temperatures = temperatures
        self.mosTemperature = mosTemperature
        self.balancerTemperature = balancerTemperature
        self.cellVoltagesMillivolts = cellVoltagesMillivolts
        self.soh = soh
        self.power = power
        self.runtimeSeconds = runtimeSeconds
        self.voltageDiffMillivolts = voltageDiffMillivolts
        self.chargeMOSOn = chargeMOSOn
        self.dischargeMOSOn = dischargeMOSOn
        self.balanceStatus = balanceStatus
        self.balanceMask = balanceMask
        self.statusCode = statusCode
        self.statusText = statusText
        self.frameLength = frameLength
        self.unparsedBytes = unparsedBytes
    }

    public var isFreshCandidate: Bool { frameLength > 0 && totalVoltage > 0 }
    public var maxCellVoltageMillivolts: Int? { cellVoltagesMillivolts.max() }
    public var minCellVoltageMillivolts: Int? { cellVoltagesMillivolts.min() }
}
