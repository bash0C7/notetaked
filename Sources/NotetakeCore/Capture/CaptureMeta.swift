import Foundation

/// 1つのsourceの取り込みの状態
public enum CaptureSourceState: String, Codable, Sendable {
    case recording
    case retrying
    case off
}

/// sample番号と壁時計（epoch ms）の対応
public struct CaptureAnchor: Codable, Equatable, Sendable {
    public var sample: Int64
    public var ms: Int64

    public init(sample: Int64, ms: Int64) {
        self.sample = sample
        self.ms = ms
    }
}

/// `<source>.meta.jsonl`の1行
public enum CaptureMetaLine: Equatable, Sendable {
    /// sample番号と壁時計の対応。その後のsampleは16kHzで進める
    case anchor(CaptureAnchor)
    /// そのsample以降の入力機器。micだけが書く
    case device(sample: Int64, device: InputDevice)
    /// 取り込みの停止と再開、書き込みの失敗の記録。表示と調査に使う
    case state(sample: Int64, ms: Int64, state: CaptureSourceState, reason: String?)
}

extension CaptureMetaLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, sample, ms, device, state, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        let sample = try container.decode(Int64.self, forKey: .sample)
        switch type {
        case "anchor":
            self = .anchor(CaptureAnchor(sample: sample, ms: try container.decode(Int64.self, forKey: .ms)))
        case "device":
            self = .device(sample: sample, device: try container.decode(InputDevice.self, forKey: .device))
        case "state":
            self = .state(
                sample: sample, ms: try container.decode(Int64.self, forKey: .ms),
                state: try container.decode(CaptureSourceState.self, forKey: .state),
                reason: try container.decodeIfPresent(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t, in: container, debugDescription: "unknown meta line type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anchor(let anchor):
            try container.encode("anchor", forKey: .t)
            try container.encode(anchor.sample, forKey: .sample)
            try container.encode(anchor.ms, forKey: .ms)
        case .device(let sample, let device):
            try container.encode("device", forKey: .t)
            try container.encode(sample, forKey: .sample)
            try container.encode(device, forKey: .device)
        case .state(let sample, let ms, let state, let reason):
            try container.encode("state", forKey: .t)
            try container.encode(sample, forKey: .sample)
            try container.encode(ms, forKey: .ms)
            try container.encode(state, forKey: .state)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(line: String) throws -> CaptureMetaLine {
        try JSONDecoder().decode(CaptureMetaLine.self, from: Data(line.utf8))
    }
}
