import Foundation

/// Watch側で起きた出来事の種類。rawValueはsnake_case（記録の`event`に出る）
public enum WatchObsEvent: String, Codable, Sendable {
    case launched
    case scenePhase = "scene_phase"
    case started
    case startFailed = "start_failed"
    case stopped
    case halted
    case interruptionBegan = "interruption_began"
    case interruptionEnded = "interruption_ended"
    case configurationChanged = "configuration_changed"
    case mediaServicesReset = "media_services_reset"
    case chunkClosed = "chunk_closed"
    case writeFailed = "write_failed"
    case transferFinished = "transfer_finished"
    case transferFailed = "transfer_failed"
    case tapQueue = "tap_queue"
}

/// Watchの記録の1行（JSON Lines）。`nil`の項目は出さない
public struct WatchObsRecord: Codable, Sendable, Equatable {
    public var atMS: Int64
    public var event: WatchObsEvent
    public var session: String?
    public var index: Int?
    public var detail: String?
    public var value: Double?
    /// 待ち行列の遅れ（ms）。`tapQueue`では深さを`value`、遅れをこれに載せる
    public var lagMS: Int64?

    public init(
        atMS: Int64,
        event: WatchObsEvent,
        session: String? = nil,
        index: Int? = nil,
        detail: String? = nil,
        value: Double? = nil,
        lagMS: Int64? = nil
    ) {
        self.atMS = atMS
        self.event = event
        self.session = session
        self.index = index
        self.detail = detail
        self.value = value
        self.lagMS = lagMS
    }

    private enum CodingKeys: String, CodingKey {
        case atMS = "at_ms"
        case event
        case session
        case index
        case detail
        case value
        case lagMS = "lag_ms"
    }

    /// 改行なしの1行。keyの並びは固定
    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// 空行・壊れた行・未知の`event`の行は飛ばす
    public static func decodeLines(_ text: String) -> [WatchObsRecord] {
        let decoder = JSONDecoder()
        // Characterの改行判定だとU+2028 / U+0085で割れ、"\r\n"も1文字になる。バイトの"\n"だけで割る
        return text.utf8.split(separator: 0x0A).compactMap { line in
            var bytes = Data(Array(line))
            if bytes.last == 0x0D { bytes.removeLast() }
            return try? decoder.decode(WatchObsRecord.self, from: bytes)
        }
    }
}

/// `transferFile`の中身の種類。旧形式の小片のmetadataには`kind`が無い
public enum WatchTransferKind: Sendable, Equatable {
    case chunk
    case obs

    public static func of(_ metadata: [String: Any]) -> WatchTransferKind {
        (metadata["kind"] as? String) == "obs" ? .obs : .chunk
    }
}

/// 記録ファイル（JSON Lines）を`transferFile`で送る時のmetadata。
/// keyは`kind`, `device`, `created_at_ms`。小片のmetadataとして読めてはならない
public struct WatchObsFileMetadata: Sendable, Equatable {
    public var device: String
    public var createdAtMS: Int64

    public init(device: String, createdAtMS: Int64) {
        self.device = device
        self.createdAtMS = createdAtMS
    }

    /// 型が合わなければnil（`created_at_ms`はNSNumber/Int/Int64/Doubleを許容）
    public init?(metadata: [String: Any]) {
        guard
            WatchTransferKind.of(metadata) == .obs,
            let device = metadata["device"] as? String,
            let createdAtMS = Self.int64Value(metadata["created_at_ms"])
        else {
            return nil
        }
        self.device = device
        self.createdAtMS = createdAtMS
    }

    public var metadata: [String: Any] {
        [
            "kind": "obs",
            "device": device,
            "created_at_ms": createdAtMS,
        ]
    }

    public var fileName: String {
        "\(device)-\(createdAtMS).jsonl"
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        switch any {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(exactly: value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }
}
