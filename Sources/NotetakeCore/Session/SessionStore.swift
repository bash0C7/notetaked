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

    private var liveHandle: FileHandle?
    private var timedHandle: FileHandle?

    public init(directory: URL, prefix: String) {
        self.prefix = prefix
        self.liveURL = directory.appendingPathComponent("\(prefix).live.txt")
        self.timedURL = directory.appendingPathComponent("\(prefix).timed.jsonl")
        self.finalURL = directory.appendingPathComponent("\(prefix).final.md")
    }

    public init(directory: URL, start: Date, timeZone: TimeZone = .current) {
        self.init(directory: directory, prefix: SessionStore.prefix(for: start, timeZone: timeZone))
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
        let handle = try TimedFile.openForAppend(at: url)
        cached = handle
        return handle
    }
}
