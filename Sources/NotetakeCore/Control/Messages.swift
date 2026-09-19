import Foundation

public enum ControlError: Error, Equatable {
    case unknownCommand(String)
    case unknownEvent(String)
}

public enum Command: Codable, Sendable, Equatable {
    case start
    case stop
    case renameSpeaker(id: String, name: String)
    case rotate
    case pairCode(String)
    case quit

    enum CodingKeys: String, CodingKey {
        case cmd
        case speaker
        case name
        case code
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cmd = try container.decode(String.self, forKey: .cmd)
        switch cmd {
        case "start":
            self = .start
        case "stop":
            self = .stop
        case "rename_speaker":
            let speaker = try container.decode(String.self, forKey: .speaker)
            let name = try container.decode(String.self, forKey: .name)
            self = .renameSpeaker(id: speaker, name: name)
        case "rotate":
            self = .rotate
        case "pair_code":
            let code = try container.decode(String.self, forKey: .code)
            self = .pairCode(code)
        case "quit":
            self = .quit
        default:
            throw ControlError.unknownCommand(cmd)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start:
            try container.encode("start", forKey: .cmd)
        case .stop:
            try container.encode("stop", forKey: .cmd)
        case .renameSpeaker(let id, let name):
            try container.encode("rename_speaker", forKey: .cmd)
            try container.encode(id, forKey: .speaker)
            try container.encode(name, forKey: .name)
        case .rotate:
            try container.encode("rotate", forKey: .cmd)
        case .pairCode(let code):
            try container.encode("pair_code", forKey: .cmd)
            try container.encode(code, forKey: .code)
        case .quit:
            try container.encode("quit", forKey: .cmd)
        }
    }

    public static func decode(line: String) throws -> Command {
        try JSONDecoder().decode(Command.self, from: Data(line.utf8))
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct StatusEvent: Codable, Sendable, Equatable {
    public var recording: Bool
    public var prefix: String?          // 収録中のファイル接頭辞
    public var sources: [Source]
    public var inputName: String?       // key: input_name
    public var inputSpatial: Bool?      // key: input_spatial
    public var outputDirectory: String  // key: output_directory

    enum CodingKeys: String, CodingKey {
        case recording
        case prefix
        case sources
        case inputName = "input_name"
        case inputSpatial = "input_spatial"
        case outputDirectory = "output_directory"
    }

    public init(
        recording: Bool,
        prefix: String? = nil,
        sources: [Source],
        inputName: String? = nil,
        inputSpatial: Bool? = nil,
        outputDirectory: String
    ) {
        self.recording = recording
        self.prefix = prefix
        self.sources = sources
        self.inputName = inputName
        self.inputSpatial = inputSpatial
        self.outputDirectory = outputDirectory
    }
}

public enum Event: Codable, Sendable, Equatable {
    case status(StatusEvent)
    case utterance(Utterance)
    case volatile(source: Source, text: String)
    case error(String)
    case log(String)
    case peer(device: String, deviceName: String, connected: Bool)
    /// pinした入力デバイスが切断され、OS既定入力へフォールバックした
    case inputReset

    enum CodingKeys: String, CodingKey {
        case ev
        case source
        case text
        case message
        case device
        case deviceName = "device_name"
        case connected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ev = try container.decode(String.self, forKey: .ev)
        switch ev {
        case "status":
            self = .status(try StatusEvent(from: decoder))
        case "utterance":
            self = .utterance(try Utterance(from: decoder))
        case "volatile":
            let source = try container.decode(Source.self, forKey: .source)
            let text = try container.decode(String.self, forKey: .text)
            self = .volatile(source: source, text: text)
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message)
        case "log":
            let message = try container.decode(String.self, forKey: .message)
            self = .log(message)
        case "peer":
            let device = try container.decode(String.self, forKey: .device)
            let deviceName = try container.decode(String.self, forKey: .deviceName)
            let connected = try container.decode(Bool.self, forKey: .connected)
            self = .peer(device: device, deviceName: deviceName, connected: connected)
        case "input_reset":
            self = .inputReset
        default:
            throw ControlError.unknownEvent(ev)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let payload):
            try container.encode("status", forKey: .ev)
            try payload.encode(to: encoder)
        case .utterance(let payload):
            try container.encode("utterance", forKey: .ev)
            try payload.encode(to: encoder)
        case .volatile(let source, let text):
            try container.encode("volatile", forKey: .ev)
            try container.encode(source, forKey: .source)
            try container.encode(text, forKey: .text)
        case .error(let message):
            try container.encode("error", forKey: .ev)
            try container.encode(message, forKey: .message)
        case .log(let message):
            try container.encode("log", forKey: .ev)
            try container.encode(message, forKey: .message)
        case .peer(let device, let deviceName, let connected):
            try container.encode("peer", forKey: .ev)
            try container.encode(device, forKey: .device)
            try container.encode(deviceName, forKey: .deviceName)
            try container.encode(connected, forKey: .connected)
        case .inputReset:
            try container.encode("input_reset", forKey: .ev)
        }
    }

    public static func decode(line: String) throws -> Event {
        try JSONDecoder().decode(Event.self, from: Data(line.utf8))
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
