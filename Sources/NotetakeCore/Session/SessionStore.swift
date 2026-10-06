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

    public init(directory: URL, prefix: String) {
        self.prefix = prefix
        self.liveURL = directory.appendingPathComponent("\(prefix).live.txt")
        self.timedURL = directory.appendingPathComponent("\(prefix).timed.jsonl")
        self.finalURL = directory.appendingPathComponent("\(prefix).final.md")
        self.speakersURL = directory.appendingPathComponent("\(prefix).speakers.json")
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

    /// 書き手が落ちて改行で終わっていない最後の行は、その行だけが壊れた行になるよう改行で閉じてから追記する。
    /// 末尾へ移動して返す
    private func closeUnterminatedLastLine(of handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        let last = try handle.read(upToCount: 1)
        try handle.seekToEnd()
        if last != Data([0x0A]) {
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    private func openHandle(at url: URL, cached: inout FileHandle?) throws -> FileHandle {
        if let handle = cached {
            return handle
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: url)
        try closeUnterminatedLastLine(of: handle)
        cached = handle
        return handle
    }
}
