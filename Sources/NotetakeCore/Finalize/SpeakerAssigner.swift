import Foundation

/// オフライン話者分離が出した、1人の話者が話している区間（音声の先頭からのms）
public struct SpeakerTurn: Equatable, Sendable {
    public var speaker: String
    public var startMS: Int64
    public var endMS: Int64

    public init(speaker: String, startMS: Int64, endMS: Int64) {
        self.speaker = speaker
        self.startMS = startMS
        self.endMS = endMS
    }
}

/// 一括文字起こしの結果1件。`runs`は時間範囲を持つテキスト片（音声の先頭からのms）
public struct TranscribedPhrase: Equatable, Sendable {
    public var runs: [TranscriptRun]
    public var confidence: Double?

    public init(runs: [TranscriptRun], confidence: Double?) {
        self.runs = runs
        self.confidence = confidence
    }
}

public struct AssignedUtterance: Equatable, Sendable {
    public var speaker: String?
    public var text: String
    public var startMS: Int64
    public var endMS: Int64
    public var confidence: Double?
}

/// 文字起こしのrunごとに話者を割り当て、同じ話者が続く範囲を1つの発話にまとめる純粋関数
public enum SpeakerAssigner {
    /// - 重なりが最大の話者を選ぶ。重なりが無いrunは、時間的に最も近い区間の話者を使う。話者の区間が無ければnil
    /// - 発話は文字起こしの結果1件の中でだけまとめる。結果の境目をまたいで1つにしない
    /// - `turns`は重ならない前提（FluidAudioの`exclusiveSegments`）。開始時刻の二分探索で候補を絞る
    public static func assign(phrases: [TranscribedPhrase], turns: [SpeakerTurn]) -> [AssignedUtterance] {
        let sortedTurns = turns.sorted { ($0.startMS, $0.endMS) < ($1.startMS, $1.endMS) }
        var utterances: [AssignedUtterance] = []
        for phrase in phrases {
            var current: (speaker: String?, runs: [TranscriptRun])?
            for run in phrase.runs {
                let speaker = speaker(for: run, in: sortedTurns)
                if let existing = current, existing.speaker == speaker {
                    current?.runs.append(run)
                } else {
                    if let finished = current {
                        append(finished, confidence: phrase.confidence, to: &utterances)
                    }
                    current = (speaker, [run])
                }
            }
            if let finished = current {
                append(finished, confidence: phrase.confidence, to: &utterances)
            }
        }
        return utterances
    }

    private static func append(
        _ group: (speaker: String?, runs: [TranscriptRun]), confidence: Double?,
        to utterances: inout [AssignedUtterance]
    ) {
        let text = group.runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let first = group.runs.first else { return }
        utterances.append(
            AssignedUtterance(
                speaker: group.speaker, text: text, startMS: first.startMS,
                endMS: group.runs.map(\.endMS).max() ?? first.endMS, confidence: confidence))
    }

    private static func speaker(for run: TranscriptRun, in turns: [SpeakerTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        // runの終わり以降に始まる最初の区間
        var low = 0
        var high = turns.count
        while low < high {
            let middle = (low + high) / 2
            if turns[middle].startMS < run.endMS {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let next = low
        // runの始まりより後に終わる区間を遡る。最初に見つかった、それより前に終わる区間までを候補にする
        var lower = next - 1
        while lower > 0 && turns[lower].endMS > run.startMS {
            lower -= 1
        }
        lower = max(lower, 0)
        let upper = min(next, turns.count - 1)

        var best: (index: Int, overlap: Int64, distance: Int64)?
        for index in lower...upper {
            let turn = turns[index]
            let overlap = max(0, min(turn.endMS, run.endMS) - max(turn.startMS, run.startMS))
            let distance =
                overlap > 0 ? 0 : max(0, turn.startMS - run.endMS, run.startMS - turn.endMS)
            if let current = best {
                let better =
                    overlap > current.overlap
                    || (overlap == 0 && current.overlap == 0 && distance < current.distance)
                if !better { continue }
            }
            best = (index, overlap, distance)
        }
        return best.map { turns[$0.index].speaker }
    }
}
