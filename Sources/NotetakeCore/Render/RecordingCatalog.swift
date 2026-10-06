import Foundation

/// 「収録の話者」windowの一覧の1行
public struct RecordingEntry: Equatable, Sendable, Identifiable {
    public var prefix: String
    /// `<prefix>.speakers.json`の回。無ければ（従来の形式を含む）確定済みとして扱わない
    public var finalizedRun: Int?
    public var speakers: [SpeakersFile.Speaker]
    /// 生音声が残っている
    public var hasRawAudio: Bool

    public var id: String { prefix }

    /// 一覧に出す開始時刻（`2026-10-06 10:00:00`）。prefixの形でなければprefixをそのまま使う
    public var title: String {
        let parts = prefix.split(separator: "_")
        guard parts.count == 2, parts[1].count == 6 else { return prefix }
        let time = parts[1]
        return "\(parts[0]) \(time.prefix(2)):\(time.dropFirst(2).prefix(2)):\(time.suffix(2))"
    }
}

public enum DurationLabel {
    /// 発話秒数を`m:ss`にする（60分を超えれば分が3桁以上になる）
    public static func text(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public enum RecordingCatalog {
    /// 出力ディレクトリの収録を新しい順に返す。prefixは開始時刻（`yyyy-MM-dd_HHmmss`）なので、名前の降順が新しい順になる。
    /// 確定済みかどうかは`<prefix>.speakers.json`の回で、生音声の有無は一時ディレクトリで判断する
    public static func scan(
        outputDirectory: URL, rawBase: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) -> [RecordingEntry] {
        let suffix = ".timed.jsonl"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
            .sorted(by: >).map { prefix in
                let file = try? SpeakersFile.read(from: SpeakersFile.url(prefix: prefix, directory: outputDirectory))
                let sessionDirectory = CaptureSessionPaths.sessionDirectory(prefix: prefix, baseTemporaryDirectory: rawBase)
                return RecordingEntry(
                    prefix: prefix, finalizedRun: file?.run, speakers: file?.speakers ?? [],
                    hasRawAudio: FileManager.default.fileExists(
                        atPath: CaptureSessionPaths.sessionInfoURL(sessionDirectory: sessionDirectory).path))
            }
    }

    /// 一覧に出す状態の文。serveが伝えた状態があればそれを、無ければ`speakers.json`の有無で決める
    public static func statusText(entry: RecordingEntry, state: FinalizeStateEvent?) -> String {
        if let state {
            return FinalizeStatusLabel.text(for: state)
        }
        return entry.finalizedRun != nil ? "確定済み" : "未確定"
    }

    /// 確定し直せるか。生音声が残っていて、確定処理が順番待ちでも実行中でもない
    public static func canRefinalize(entry: RecordingEntry, state: FinalizeStateEvent?) -> Bool {
        guard entry.hasRawAudio else { return false }
        return state?.phase != .waiting && state?.phase != .running
    }
}
