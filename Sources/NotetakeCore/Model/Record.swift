public struct SessionRecord: Codable, Sendable, Equatable {
    public var id: String
    public var started: Int64
    public var owner: String

    public init(id: String, started: Int64, owner: String) {
        self.id = id
        self.started = started
        self.owner = owner
    }
}

public struct DeviceRecord: Codable, Sendable, Equatable {
    public var device: String
    public var deviceName: String     // key: device_name
    public var owner: String
    public var platform: Platform
    public var offsetMS: Int64        // key: offset_ms

    enum CodingKeys: String, CodingKey {
        case device
        case deviceName = "device_name"
        case owner
        case platform
        case offsetMS = "offset_ms"
    }

    public init(device: String, deviceName: String, owner: String, platform: Platform, offsetMS: Int64) {
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.platform = platform
        self.offsetMS = offsetMS
    }
}

public struct SpeakerNameRecord: Codable, Sendable, Equatable {
    public var speaker: String
    public var name: String
    /// 確定版の話者への名前は、どの回の話者かを持つ。無ければ従来の大域idへの名前
    public var run: Int?

    public init(speaker: String, name: String, run: Int? = nil) {
        self.speaker = speaker
        self.name = name
        self.run = run
    }
}

/// 収録の終了。収録の一覧が終了時刻に使う
public struct SessionEndRecord: Codable, Sendable, Equatable {
    public var ended: Int64   // epoch ms

    public init(ended: Int64) {
        self.ended = ended
    }
}

/// 確定処理の結果の取り込みが済んだ印。`device`の`sources`は、この回の確定版に置き換わる
public struct FinalizedRecord: Codable, Sendable, Equatable {
    public var run: Int
    public var device: String
    public var sources: [Source]

    public init(run: Int, device: String, sources: [Source]) {
        self.run = run
        self.device = device
        self.sources = sources
    }
}

/// 確定版の話者`from`を`into`へまとめる
public struct SpeakerMergeRecord: Codable, Sendable, Equatable {
    public var run: Int
    public var from: String
    public var into: String

    public init(run: Int, from: String, into: String) {
        self.run = run
        self.from = from
        self.into = into
    }
}

public enum Record: Codable, Sendable, Equatable {
    case session(SessionRecord)          // t: "session"
    case device(DeviceRecord)            // t: "device"
    case speakerName(SpeakerNameRecord)  // t: "speaker_name"
    case segment(Segment)                // t: "seg"
    case sessionEnd(SessionEndRecord)    // t: "session_end"
    case finalized(FinalizedRecord)      // t: "finalized"
    case speakerMerge(SpeakerMergeRecord)  // t: "speaker_merge"

    enum CodingKeys: String, CodingKey {
        case t
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "session":
            self = .session(try SessionRecord(from: decoder))
        case "device":
            self = .device(try DeviceRecord(from: decoder))
        case "speaker_name":
            self = .speakerName(try SpeakerNameRecord(from: decoder))
        case "seg":
            self = .segment(try Segment(from: decoder))
        case "session_end":
            self = .sessionEnd(try SessionEndRecord(from: decoder))
        case "finalized":
            self = .finalized(try FinalizedRecord(from: decoder))
        case "speaker_merge":
            self = .speakerMerge(try SpeakerMergeRecord(from: decoder))
        default:
            throw NDJSONError.unknownType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let payload):
            try container.encode("session", forKey: .t)
            try payload.encode(to: encoder)
        case .device(let payload):
            try container.encode("device", forKey: .t)
            try payload.encode(to: encoder)
        case .speakerName(let payload):
            try container.encode("speaker_name", forKey: .t)
            try payload.encode(to: encoder)
        case .segment(let payload):
            try container.encode("seg", forKey: .t)
            try payload.encode(to: encoder)
        case .sessionEnd(let payload):
            try container.encode("session_end", forKey: .t)
            try payload.encode(to: encoder)
        case .finalized(let payload):
            try container.encode("finalized", forKey: .t)
            try payload.encode(to: encoder)
        case .speakerMerge(let payload):
            try container.encode("speaker_merge", forKey: .t)
            try payload.encode(to: encoder)
        }
    }
}
