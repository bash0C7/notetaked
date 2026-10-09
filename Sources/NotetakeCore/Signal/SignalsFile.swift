import Foundation

/// `signals.jsonl`の先頭行。区間を持つので、`context.md`はこのファイルだけから作れる
public struct SignalsHeader: Codable, Sendable, Equatable {
    public var prefix: String
    public var start: Int64
    public var end: Int64
    public var bucketMS: Int64
    public var requestedAt: Int64

    enum CodingKeys: String, CodingKey {
        case prefix
        case start
        case end
        case bucketMS = "bucket_ms"
        case requestedAt = "requested_at"
    }

    public init(prefix: String, start: Int64, end: Int64, bucketMS: Int64, requestedAt: Int64) {
        self.prefix = prefix
        self.start = start
        self.end = end
        self.bucketMS = bucketMS
        self.requestedAt = requestedAt
    }
}

public struct SignalsDocument: Sendable, Equatable {
    public var header: SignalsHeader
    public var buckets: [SignalBucket]

    public init(header: SignalsHeader, buckets: [SignalBucket]) {
        self.header = header
        self.buckets = buckets
    }
}

public enum SignalsFileError: Error, Equatable {
    case missingHeader
    case unknownType(String)
}

/// `<prefix>.signals.jsonl`。1行目が`t: signals`のheader、2行目以降が`t: bucket`
public enum SignalsFile {
    public static func url(prefix: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(prefix).signals.jsonl")
    }

    public static func encode(_ document: SignalsDocument) throws -> String {
        var lines = [try line(type: "signals", document.header)]
        for bucket in document.buckets {
            lines.append(try line(type: "bucket", bucket))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 壊れた行は読み飛ばさずにthrowする。ファイルはアトミックに置き換えるので、壊れていれば書き手の不具合である
    public static func decode(_ text: String) throws -> SignalsDocument {
        let decoder = JSONDecoder()
        var header: SignalsHeader?
        var buckets: [SignalBucket] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(line.utf8)
            let type = try decoder.decode(TypeTag.self, from: data).t
            switch type {
            case "signals":
                header = try decoder.decode(SignalsHeader.self, from: data)
            case "bucket":
                buckets.append(try decoder.decode(SignalBucket.self, from: data))
            default:
                throw SignalsFileError.unknownType(type)
            }
        }
        guard let header else { throw SignalsFileError.missingHeader }
        return SignalsDocument(header: header, buckets: buckets)
    }

    private struct TypeTag: Decodable {
        var t: String
    }

    private struct Tagged<Payload: Encodable>: Encodable {
        let type: String
        let payload: Payload

        enum CodingKeys: String, CodingKey {
            case t
        }

        func encode(to encoder: Encoder) throws {
            try payload.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .t)
        }
    }

    private static func line<Payload: Encodable>(type: String, _ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(Tagged(type: type, payload: payload)), as: UTF8.self)
    }
}
