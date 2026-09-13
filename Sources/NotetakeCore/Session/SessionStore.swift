import Foundation

public actor SessionStore {
    /// "yyyy-MM-dd_HHmmss"（en_US_POSIX、指定timeZone）
    public static func prefix(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    public nonisolated let prefix: String
    public nonisolated let liveURL: URL
    public nonisolated let timedURL: URL
    public nonisolated let finalURL: URL
    public nonisolated let speakersURL: URL

    private var liveHandle: FileHandle?
    private var timedHandle: FileHandle?

    public init(directory: URL, start: Date, timeZone: TimeZone = .current) {
        let prefix = SessionStore.prefix(for: start, timeZone: timeZone)
        self.prefix = prefix
        self.liveURL = directory.appendingPathComponent("\(prefix).live.txt")
        self.timedURL = directory.appendingPathComponent("\(prefix).timed.jsonl")
        self.finalURL = directory.appendingPathComponent("\(prefix).final.md")
        self.speakersURL = directory.appendingPathComponent("\(prefix).speakers.json")
    }

    /// timed.jsonlへ `NDJSON.encode(record) + "\n"` を追記。`.segment`で`platform == .mac`なら live.txt へ `text + "\n"` も追記。ファイルは初回appendで作成、FileHandleは開いたまま保持
    public func append(_ record: Record) throws {
        let timedHandle = try openHandle(at: timedURL, cached: &timedHandle)
        try timedHandle.write(contentsOf: Data((try NDJSON.encode(record) + "\n").utf8))

        if case .segment(let segment) = record, segment.platform == .mac {
            let liveHandle = try openHandle(at: liveURL, cached: &liveHandle)
            try liveHandle.write(contentsOf: Data((segment.text + "\n").utf8))
        }
    }

    /// final.mdを上書き（atomic）
    public func writeFinal(_ markdown: String) throws {
        try Data(markdown.utf8).write(to: finalURL, options: .atomic)
    }

    /// speakers.jsonを上書き（JSON、sortedKeys、prettyPrinted、atomic）
    public func writeSpeakers(_ profiles: [SpeakerProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(profiles)
        try data.write(to: speakersURL, options: .atomic)
    }

    public func close() {
        try? timedHandle?.close()
        try? liveHandle?.close()
        timedHandle = nil
        liveHandle = nil
    }

    private func openHandle(at url: URL, cached: inout FileHandle?) throws -> FileHandle {
        if let handle = cached {
            return handle
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        cached = handle
        return handle
    }
}
