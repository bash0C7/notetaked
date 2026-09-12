import Foundation

public enum NDJSONError: Error, Equatable {
    case unknownType(String)
}

public enum NDJSON {
    public static func encode(_ record: Record) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ line: String) throws -> Record {
        try JSONDecoder().decode(Record.self, from: Data(line.utf8))
    }

    public static func decodeAll(_ text: String) -> [Record] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            try? decode(String(line))
        }
    }
}
