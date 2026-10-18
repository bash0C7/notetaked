import Foundation

public enum WatchRecordingState: String, Codable, Sendable, Equatable {
    case recording, halted, stopped, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WatchRecordingState(rawValue: raw) ?? .unknown
    }
}

/// 小片1つ分のレベル。iPhoneが集計してMacへ中継する
public struct WatchChunkLevel: Codable, Sendable, Equatable {
    public var index: Int
    public var startAtMS: Int64
    public var durationMS: Int64?
    public var maxDBFS: Double?
    public var meanDBFS: Double?

    public init(index: Int, startAtMS: Int64, durationMS: Int64? = nil, maxDBFS: Double? = nil, meanDBFS: Double? = nil) {
        self.index = index
        self.startAtMS = startAtMS
        self.durationMS = durationMS
        self.maxDBFS = maxDBFS
        self.meanDBFS = meanDBFS
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case startAtMS = "start_at_ms"
        case durationMS = "duration_ms"
        case maxDBFS = "max_dbfs"
        case meanDBFS = "mean_dbfs"
    }
}

/// iPhoneが組み立て、Macへ`watch_status`で送るWatchの状態。JSONはsnake_caseで`nil`の項目は出さない
public struct WatchStatusSnapshot: Codable, Sendable, Equatable {
    /// `levels`の最大件数（新しい順。20秒の小片で30分）
    public static let maxLevels = 90

    public var device: String
    public var deviceName: String
    public var session: String?
    public var state: WatchRecordingState
    /// 未知の値は読み込みでnilにする
    public var haltReason: WatchHaltReason?
    public var haltDetail: String?
    public var stateAtMS: Int64?
    public var lastChunkReceivedAtMS: Int64?
    public var lastChunkIndex: Int?
    public var missingChunkCount: Int
    /// 新しい順（先頭が最新の小片）
    public var levels: [WatchChunkLevel]
    public var batteryLevel: Double?
    public var batteryAtMS: Int64?
    public var lastText: String?
    public var lastTextAtMS: Int64?
    public var inboxPendingCount: Int
    public var updatedAtMS: Int64

    public init(
        device: String,
        deviceName: String,
        session: String? = nil,
        state: WatchRecordingState = .unknown,
        haltReason: WatchHaltReason? = nil,
        haltDetail: String? = nil,
        stateAtMS: Int64? = nil,
        lastChunkReceivedAtMS: Int64? = nil,
        lastChunkIndex: Int? = nil,
        missingChunkCount: Int = 0,
        levels: [WatchChunkLevel] = [],
        batteryLevel: Double? = nil,
        batteryAtMS: Int64? = nil,
        lastText: String? = nil,
        lastTextAtMS: Int64? = nil,
        inboxPendingCount: Int = 0,
        updatedAtMS: Int64
    ) {
        self.device = device
        self.deviceName = deviceName
        self.session = session
        self.state = state
        self.haltReason = haltReason
        self.haltDetail = haltDetail
        self.stateAtMS = stateAtMS
        self.lastChunkReceivedAtMS = lastChunkReceivedAtMS
        self.lastChunkIndex = lastChunkIndex
        self.missingChunkCount = missingChunkCount
        self.levels = levels
        self.batteryLevel = batteryLevel
        self.batteryAtMS = batteryAtMS
        self.lastText = lastText
        self.lastTextAtMS = lastTextAtMS
        self.inboxPendingCount = inboxPendingCount
        self.updatedAtMS = updatedAtMS
    }

    private enum CodingKeys: String, CodingKey {
        case device
        case deviceName = "device_name"
        case session
        case state
        case haltReason = "halt_reason"
        case haltDetail = "halt_detail"
        case stateAtMS = "state_at_ms"
        case lastChunkReceivedAtMS = "last_chunk_received_at_ms"
        case lastChunkIndex = "last_chunk_index"
        case missingChunkCount = "missing_chunk_count"
        case levels
        case batteryLevel = "battery_level"
        case batteryAtMS = "battery_at_ms"
        case lastText = "last_text"
        case lastTextAtMS = "last_text_at_ms"
        case inboxPendingCount = "inbox_pending_count"
        case updatedAtMS = "updated_at_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(String.self, forKey: .device)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        state = try c.decode(WatchRecordingState.self, forKey: .state)
        haltReason = (try c.decodeIfPresent(String.self, forKey: .haltReason)).flatMap(WatchHaltReason.init(rawValue:))
        haltDetail = try c.decodeIfPresent(String.self, forKey: .haltDetail)
        stateAtMS = try c.decodeIfPresent(Int64.self, forKey: .stateAtMS)
        lastChunkReceivedAtMS = try c.decodeIfPresent(Int64.self, forKey: .lastChunkReceivedAtMS)
        lastChunkIndex = try c.decodeIfPresent(Int.self, forKey: .lastChunkIndex)
        missingChunkCount = try c.decode(Int.self, forKey: .missingChunkCount)
        levels = try c.decode([WatchChunkLevel].self, forKey: .levels)
        batteryLevel = try c.decodeIfPresent(Double.self, forKey: .batteryLevel)
        batteryAtMS = try c.decodeIfPresent(Int64.self, forKey: .batteryAtMS)
        lastText = try c.decodeIfPresent(String.self, forKey: .lastText)
        lastTextAtMS = try c.decodeIfPresent(Int64.self, forKey: .lastTextAtMS)
        inboxPendingCount = try c.decode(Int.self, forKey: .inboxPendingCount)
        updatedAtMS = try c.decode(Int64.self, forKey: .updatedAtMS)
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(json: String) throws -> WatchStatusSnapshot {
        try JSONDecoder().decode(WatchStatusSnapshot.self, from: Data(json.utf8))
    }
}
