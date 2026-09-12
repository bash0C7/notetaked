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

    public init(speaker: String, name: String) {
        self.speaker = speaker
        self.name = name
    }
}

public enum Record: Codable, Sendable, Equatable {
    case session(SessionRecord)          // t: "session"
    case device(DeviceRecord)            // t: "device"
    case speakerName(SpeakerNameRecord)  // t: "speaker_name"
    case segment(Segment)                // t: "seg"

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
        }
    }
}
