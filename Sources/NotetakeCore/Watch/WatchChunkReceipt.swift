import Foundation

/// iPhoneが小片を受け取った記録（JSON Lines）。`Documents/watch-obs/receipts-<device>.jsonl`へ1行ずつ足す。
/// 音声は載せず、`nil`の項目は出さない
public struct WatchChunkReceipt: Codable, Sendable, Equatable {
    public var device: String
    public var session: String
    public var index: Int
    public var startAtMS: Int64
    public var durationMS: Int64?
    public var maxDBFS: Double?
    public var meanDBFS: Double?
    public var batteryLevel: Double?
    public var maxQueueDepth: Int?
    public var isFinal: Bool?
    public var receivedAtMS: Int64

    public init(metadata: WatchChunkMetadata, receivedAtMS: Int64) {
        device = metadata.device
        session = metadata.session
        index = metadata.index
        startAtMS = metadata.startAtMS
        durationMS = metadata.durationMS
        maxDBFS = metadata.maxDBFS
        meanDBFS = metadata.meanDBFS
        batteryLevel = metadata.batteryLevel
        maxQueueDepth = metadata.maxQueueDepth
        isFinal = metadata.isFinal
        self.receivedAtMS = receivedAtMS
    }

    private enum CodingKeys: String, CodingKey {
        case device, session, index
        case startAtMS = "start_at_ms"
        case durationMS = "duration_ms"
        case maxDBFS = "max_dbfs"
        case meanDBFS = "mean_dbfs"
        case batteryLevel = "battery_level"
        case maxQueueDepth = "max_queue_depth"
        case isFinal = "is_final"
        case receivedAtMS = "received_at_ms"
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// 空行・壊れた行は飛ばす。`WatchObsRecord.decodeLines`と同じくbyteの`\n`で割る
    public static func decodeLines(_ text: String) -> [WatchChunkReceipt] {
        let decoder = JSONDecoder()
        return text.utf8.split(separator: 0x0A).compactMap { line in
            var bytes = Data(Array(line))
            if bytes.last == 0x0D { bytes.removeLast() }
            return try? decoder.decode(WatchChunkReceipt.self, from: bytes)
        }
    }
}
