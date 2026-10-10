import Foundation

/// 日志用的数据转储工具。协议排障依赖「原始字节可见」，
/// 因此统一在此提供十六进制表示，避免各处重复实现。
public enum LogHexDump {
    /// 将字节序列转为 `7E A1 11 ...` 形式的大写十六进制字符串。
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 压缩展示：超过 `limit` 字节时截断，并标注原始长度。
    /// - Parameters:
    ///   - data: 原始数据。
    ///   - limit: 最多展示的字节数，默认 64。
    public static func shortenedHex(_ data: Data, limit: Int = 64) -> String {
        if data.count <= limit {
            return hex(data)
        }
        let head = hex(Data(data.prefix(limit)))
        return "\(head) … (+\(data.count - limit) bytes, total \(data.count))"
    }
}
