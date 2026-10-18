import Foundation
import NotetakeCore

/// 実機gate（R1〜R8）の計測の記録。`Documents/relay-trace/<yyyy-MM-dd>.jsonl`へ`RelayTraceRecord`を1行ずつ足す
/// （`devicectl device copy from`で取り出せるようDocuments配下）。書き込みは専用のserial queueで行い、
/// 呼び出し側（callbackの中・MainActor）を待たせない
enum RelayTrace {
    private static let queue = DispatchQueue(label: "io.github.bash0c7.notetake.relay-trace", qos: .utility)

    static func directory() -> URL {
        let base: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("relay-trace", isDirectory: true)
    }

    static func record(
        _ event: RelayTraceEvent, appState: String? = nil, remainingSeconds: Double? = nil,
        device: String? = nil, session: String? = nil, index: Int? = nil, seq: Int? = nil,
        endAtMS: Int64? = nil, detail: String? = nil
    ) {
        let record = RelayTraceRecord(
            atMS: Int64((Date().timeIntervalSince1970 * 1000).rounded()), event: event, appState: appState,
            remainingSeconds: remainingSeconds, device: device, session: session, index: index, seq: seq,
            endAtMS: endAtMS, detail: detail)
        queue.async { append(record) }
    }

    private static func append(_ record: RelayTraceRecord) {
        guard let line = try? record.encodedLine() else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = formatter.string(from: Date(timeIntervalSince1970: Double(record.atMS) / 1000)) + ".jsonl"
        let directory = directory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
