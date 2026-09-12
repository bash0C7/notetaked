import Foundation

public enum Platform: String, Codable, Sendable {
    case mac, ios, watchos
}

public enum Source: String, Codable, Sendable {
    case mic, system, watch
}

public struct SpeakerTag: Codable, Sendable, Equatable {
    public var local: String?        // stream内のlocal id（話者分離が付ける、M3）
    public var global: String?       // Mac側SpeakerRegistryが付けた大域id（M3）
    public var embedding: [Float]?   // 256次元（M3）

    public init(local: String? = nil, global: String? = nil, embedding: [Float]? = nil) {
        self.local = local
        self.global = global
        self.embedding = embedding
    }
}

public struct Segment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var session: String
    public var seq: Int
    public var device: String
    public var deviceName: String     // key: device_name
    public var owner: String          // 話者の既定ラベル。systemは"リモート"
    public var platform: Platform
    public var source: Source
    public var start: Int64           // epoch ms（デバイス時計）
    public var end: Int64
    public var text: String
    public var confidence: Double?
    public var levelDBFS: Double?     // key: level_dbfs
    public var speaker: SpeakerTag?
    public var clockOffsetMS: Int64   // key: clock_offset_ms、Macが受信時に付与。既定0
    public var receivedAt: Int64?     // key: received_at

    enum CodingKeys: String, CodingKey {
        case id
        case session
        case seq
        case device
        case deviceName = "device_name"
        case owner
        case platform
        case source
        case start
        case end
        case text
        case confidence
        case levelDBFS = "level_dbfs"
        case speaker
        case clockOffsetMS = "clock_offset_ms"
        case receivedAt = "received_at"
    }

    public init(
        id: UUID,
        session: String,
        seq: Int,
        device: String,
        deviceName: String,
        owner: String,
        platform: Platform,
        source: Source,
        start: Int64,
        end: Int64,
        text: String,
        confidence: Double? = nil,
        levelDBFS: Double? = nil,
        speaker: SpeakerTag? = nil,
        clockOffsetMS: Int64 = 0,
        receivedAt: Int64? = nil
    ) {
        self.id = id
        self.session = session
        self.seq = seq
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.platform = platform
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.levelDBFS = levelDBFS
        self.speaker = speaker
        self.clockOffsetMS = clockOffsetMS
        self.receivedAt = receivedAt
    }
}
