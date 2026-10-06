import Foundation

/// 起動時に生音声ディレクトリから読む、収録1つぶんの事実
public struct RawSessionFacts: Equatable, Sendable {
    public var prefix: String
    /// `session.json`を読めた
    public var hasSessionInfo: Bool
    /// `session.json`が示す出力ディレクトリに`<prefix>.timed.jsonl`がある
    public var timedExists: Bool
    /// `timed.jsonl`にある、このMacの`finalized`の記録のうち最新の回
    public var latestFinalizedRun: Int?
    /// `finalize.json`の回
    public var resultRun: Int?
    /// 自動の再試行で失敗した回数
    public var failureCount: Int
    /// `final.md`が`timed.jsonl`より古い、または無い
    public var finalIsStale: Bool

    public init(
        prefix: String, hasSessionInfo: Bool = true, timedExists: Bool = true, latestFinalizedRun: Int? = nil,
        resultRun: Int? = nil, failureCount: Int = 0, finalIsStale: Bool = false
    ) {
        self.prefix = prefix
        self.hasSessionInfo = hasSessionInfo
        self.timedExists = timedExists
        self.latestFinalizedRun = latestFinalizedRun
        self.resultRun = resultRun
        self.failureCount = failureCount
        self.finalIsStale = finalIsStale
    }
}

public enum RecoveryAction: Equatable, Sendable {
    /// 確定処理を順番待ちへ入れる
    case finalize(prefix: String)
    /// 結果ファイルがあるのに取り込みが済んでいない。確定処理をやり直さず、結果を取り込む
    case importResult(prefix: String, run: Int)
    /// 取り込みは済んでいるが`final.md`が古い。`final.md`だけ書き直す
    case render(prefix: String)
}

public enum FinalizeRecovery {
    /// 収録中でなく、まだ確定していない収録を、古い順に返す。
    /// 自動の再試行を使い切った収録と、`session.json`や`timed.jsonl`の無い収録は入れない。
    /// 結果ファイルの回が確定済みの回より新しければ、確定し直さずに取り込む
    public static func actions(facts: [RawSessionFacts], recordingPrefix: String?) -> [RecoveryAction] {
        var actions: [RecoveryAction] = []
        for fact in facts.sorted(by: { $0.prefix < $1.prefix }) {
            guard fact.prefix != recordingPrefix, fact.hasSessionInfo, fact.timedExists else { continue }
            if let resultRun = fact.resultRun, resultRun > (fact.latestFinalizedRun ?? 0) {
                actions.append(.importResult(prefix: fact.prefix, run: resultRun))
            } else if fact.latestFinalizedRun != nil {
                if fact.finalIsStale {
                    actions.append(.render(prefix: fact.prefix))
                }
            } else if !FinalizeRetryPolicy.isGivenUp(failureCount: fact.failureCount) {
                actions.append(.finalize(prefix: fact.prefix))
            }
        }
        return actions
    }

    /// 起動時に`gaveUp`として伝える収録。確定済みでなく、自動の再試行を使い切っている
    public static func gaveUp(facts: [RawSessionFacts], recordingPrefix: String?) -> [String] {
        facts.sorted(by: { $0.prefix < $1.prefix }).filter { fact in
            fact.prefix != recordingPrefix && fact.hasSessionInfo && fact.timedExists
                && fact.latestFinalizedRun == nil && (fact.resultRun ?? 0) == 0
                && FinalizeRetryPolicy.isGivenUp(failureCount: fact.failureCount)
        }.map(\.prefix)
    }

    /// `rawBase`（`notetake-capture`の親）の下の生音声ディレクトリを調べる。読めなかったものは事実に反映し、
    /// `errors`へ理由を返す
    public static func scan(
        rawBase: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) -> (facts: [RawSessionFacts], errors: [String]) {
        let root = rawBase.appendingPathComponent("notetake-capture")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var facts: [RawSessionFacts] = []
        var errors: [String] = []
        for prefix in entries.sorted() {
            let directory = root.appendingPathComponent(prefix)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            var fact = RawSessionFacts(prefix: prefix, hasSessionInfo: false, timedExists: false)
            do {
                guard
                    let info = try JSONFile.read(
                        CaptureSessionInfo.self, from: CaptureSessionPaths.sessionInfoURL(sessionDirectory: directory))
                else {
                    facts.append(fact)
                    continue
                }
                fact.hasSessionInfo = true
                let outputDirectory = URL(fileURLWithPath: info.outputDirectory)
                let timedURL = SessionFiles.timedURL(prefix: prefix, directory: outputDirectory)
                if FileManager.default.fileExists(atPath: timedURL.path) {
                    fact.timedExists = true
                    let records = NDJSON.decodeAll(String(decoding: try Data(contentsOf: timedURL), as: UTF8.self))
                    fact.latestFinalizedRun = FinalizedRuns.latestRun(in: records, device: info.device)
                    fact.finalIsStale = isStale(
                        final: SessionFiles.finalURL(prefix: prefix, directory: outputDirectory), timed: timedURL)
                }
                fact.resultRun = try JSONFile.read(
                    FinalizeResult.self, from: CaptureSessionPaths.finalizeResultURL(sessionDirectory: directory))?.run
                fact.failureCount = try FinalizeAttempts.read(sessionDirectory: directory)
            } catch {
                errors.append("\(prefix): \(error)")
            }
            facts.append(fact)
        }
        return (facts, errors)
    }

    private static func isStale(final: URL, timed: URL) -> Bool {
        func modified(_ url: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        guard let timedDate = modified(timed) else { return false }
        guard let finalDate = modified(final) else { return true }
        return finalDate < timedDate
    }
}
