import Foundation

public enum PeerError: Error, Equatable {
    case unknownType(String)
}

public struct HelloMessage: Codable, Sendable, Equatable {
    public static let currentProtocolVersion = 1

    public var device: String
    public var deviceName: String
    public var owner: String
    public var platform: Platform
    public var protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case device
        case deviceName = "device_name"
        case owner
        case platform
        case protocolVersion = "protocol_version"
    }

    public init(
        device: String,
        deviceName: String,
        owner: String,
        platform: Platform,
        protocolVersion: Int = HelloMessage.currentProtocolVersion
    ) {
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.platform = platform
        self.protocolVersion = protocolVersion
    }
}

public struct HelloAckMessage: Codable, Sendable, Equatable {
    public var serverTimeMS: Int64
    public var accepted: Bool
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case serverTimeMS = "server_time_ms"
        case accepted
        case reason
    }

    public init(serverTimeMS: Int64, accepted: Bool, reason: String? = nil) {
        self.serverTimeMS = serverTimeMS
        self.accepted = accepted
        self.reason = reason
    }
}

/// iPhone(client)とMac(daemon, server)間のNDJSONメッセージ。型key`t`、snake_case
public enum PeerMessage: Codable, Sendable, Equatable {
    case hello(HelloMessage)
    case helloAck(HelloAckMessage)
    /// Macが送る。t0 = Mac送信時刻(ms)
    case ping(id: Int, t0: Int64)
    /// iPhoneが返す。t1 = 受信、t2 = 送信(iPhone時計)
    case pong(id: Int, t0: Int64, t1: Int64, t2: Int64)
    /// Segmentのキーをそのまま（Record.segmentと同じ形、tだけ違う）
    case seg(Segment)
    case ack(seq: Int)

    enum CodingKeys: String, CodingKey {
        case t
        case id
        case t0
        case t1
        case t2
        case seq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "hello":
            self = .hello(try HelloMessage(from: decoder))
        case "hello_ack":
            self = .helloAck(try HelloAckMessage(from: decoder))
        case "ping":
            let id = try container.decode(Int.self, forKey: .id)
            let t0 = try container.decode(Int64.self, forKey: .t0)
            self = .ping(id: id, t0: t0)
        case "pong":
            let id = try container.decode(Int.self, forKey: .id)
            let t0 = try container.decode(Int64.self, forKey: .t0)
            let t1 = try container.decode(Int64.self, forKey: .t1)
            let t2 = try container.decode(Int64.self, forKey: .t2)
            self = .pong(id: id, t0: t0, t1: t1, t2: t2)
        case "seg":
            self = .seg(try Segment(from: decoder))
        case "ack":
            let seq = try container.decode(Int.self, forKey: .seq)
            self = .ack(seq: seq)
        default:
            throw PeerError.unknownType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let payload):
            try container.encode("hello", forKey: .t)
            try payload.encode(to: encoder)
        case .helloAck(let payload):
            try container.encode("hello_ack", forKey: .t)
            try payload.encode(to: encoder)
        case .ping(let id, let t0):
            try container.encode("ping", forKey: .t)
            try container.encode(id, forKey: .id)
            try container.encode(t0, forKey: .t0)
        case .pong(let id, let t0, let t1, let t2):
            try container.encode("pong", forKey: .t)
            try container.encode(id, forKey: .id)
            try container.encode(t0, forKey: .t0)
            try container.encode(t1, forKey: .t1)
            try container.encode(t2, forKey: .t2)
        case .seg(let segment):
            try container.encode("seg", forKey: .t)
            try segment.encode(to: encoder)
        case .ack(let seq):
            try container.encode("ack", forKey: .t)
            try container.encode(seq, forKey: .seq)
        }
    }

    public static func decode(line: String) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: Data(line.utf8))
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
