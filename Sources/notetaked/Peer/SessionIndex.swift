import Foundation
import NotetakeCore

/// 出力ディレクトリ上の`*.timed.jsonl`をスキャンして過去（および現在）の収録一覧を作る純粋な
/// helper。進行中の収録の`endMS`をnilへ差し替えるのは呼び出し側（ServeSession）の責務
struct SessionIndex {
    /// `directory`直下の`*.timed.jsonl`それぞれを1件の`SessionSpan`にする。
    /// - startMS: 先頭の`session`recordの`started`。session recordが無いファイルは無視する
    /// - endMS: 全`segment`recordの`end + clock_offset_ms`の最大値。segmentが1件も無ければstartMS
    static func scan(directory: URL) -> [SessionSpan] {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        var spans: [SessionSpan] = []
        for url in entries where url.lastPathComponent.hasSuffix(".timed.jsonl") {
            let prefix = String(url.lastPathComponent.dropLast(".timed.jsonl".count))
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let records = NDJSON.decodeAll(text)

            guard
                let startMS = records.lazy.compactMap({ record -> Int64? in
                    guard case .session(let session) = record else { return nil }
                    return session.started
                }).first
            else { continue }

            let segmentEndTimes: [Int64] = records.compactMap { record in
                guard case .segment(let segment) = record else { return nil }
                return segment.end + segment.clockOffsetMS
            }
            let endMS = segmentEndTimes.max() ?? startMS

            spans.append(SessionSpan(prefix: prefix, startMS: startMS, endMS: endMS))
        }
        return spans.sorted { $0.startMS < $1.startMS }
    }

    static func timedURL(directory: URL, prefix: String) -> URL {
        directory.appendingPathComponent("\(prefix).timed.jsonl")
    }

    static func finalURL(directory: URL, prefix: String) -> URL {
        directory.appendingPathComponent("\(prefix).final.md")
    }
}
