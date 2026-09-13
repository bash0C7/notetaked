import Foundation

/// Aligner.add(piece:)への入力。TranscriptPieceの写しだが、Speechフレームワークに
/// 依存しない（`#if canImport(Speech)`の外でも使える）。
public struct AlignerInput: Sendable, Equatable {
    public var text: String
    public var startMS: Int64
    public var endMS: Int64
    public var confidence: Double?
    public var runs: [TranscriptRun]

    public init(
        text: String, startMS: Int64, endMS: Int64, confidence: Double? = nil,
        runs: [TranscriptRun] = []
    ) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
        self.confidence = confidence
        self.runs = runs
    }
}

#if canImport(Speech)
    extension AlignerInput {
        public init(_ piece: TranscriptPiece) {
            self.init(
                text: piece.text, startMS: piece.startMS, endMS: piece.endMS,
                confidence: piece.confidence, runs: piece.runs)
        }
    }
#endif

/// Alignerが分割・話者付けした結果の1片。
public struct AlignedPiece: Sendable, Equatable {
    public var text: String
    public var startMS: Int64
    public var endMS: Int64
    public var confidence: Double?
    public var localSpeaker: String?
    public var embedding: [Float]?

    public init(
        text: String, startMS: Int64, endMS: Int64, confidence: Double? = nil,
        localSpeaker: String? = nil, embedding: [Float]? = nil
    ) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
        self.confidence = confidence
        self.localSpeaker = localSpeaker
        self.embedding = embedding
    }
}

/// TranscriberのfinalなAlignerInputを、Diarizerが返すSpeakerTurnの境界で分割する
/// 純粋な状態機械。ネットワークやモデルには依存しない。
public struct Aligner: Sendable {
    public struct Config: Sendable {
        /// 分離結果がpieceの範囲を覆うのを待つ上限（ms）。これを超えたら
        /// 話者が分かる範囲だけで（無ければnilのまま）出す。
        public var holdLimitMS: Int64 = 12_000
        public init() {}
    }

    private let config: Config

    /// 到着順に並んだ、まだ出力されていないfinal piece。
    private var pending: [AlignerInput] = []
    /// これまでに受け取った全turn（メモリを抑えるため定期的にpruneする）。
    private var turns: [SpeakerTurn] = []
    /// この時刻までの分離結果が揃っている（単調増加）。
    private var coveredUntilMS: Int64 = .min

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 分離済み範囲を進める。turnsを追記し、coveredUntilMSを（既存値との）最大値に更新する。
    /// 保留中の最も古いpieceのstartMSより60秒以上前に終わったturnは破棄する。
    public mutating func add(turns newTurns: [SpeakerTurn], coveredUntilMS newCoveredUntilMS: Int64)
    {
        turns.append(contentsOf: newTurns)
        coveredUntilMS = max(coveredUntilMS, newCoveredUntilMS)

        // 保留pieceより60秒以上古いturnは不要。保留が無ければ分離済み範囲を基準に刈る
        // （無音が続いてfinalが来ない間もturnsが無制限に増えないようにする）
        let threshold = (pending.first?.startMS ?? coveredUntilMS) - 60_000
        turns.removeAll { $0.endMS < threshold }
    }

    /// final pieceを保留列へ追加する。テキストが空のpieceは捨てる。
    public mutating func add(piece: AlignerInput) {
        guard !piece.text.isEmpty else { return }
        pending.append(piece)
    }

    /// 覆われている（もしくは保留上限を超えた）先頭からのpieceを分割して出す。
    /// 順序を保つため、覆われていないpieceに当たった時点で走査を止める
    /// （それより後のpieceを先に出すことはしない）。
    public mutating func drain(nowMS: Int64) -> [AlignedPiece] {
        var result: [AlignedPiece] = []
        while let first = pending.first {
            let isCovered = first.endMS <= coveredUntilMS
            let isExpired = nowMS - first.endMS > config.holdLimitMS
            guard isCovered || isExpired else { break }
            pending.removeFirst()
            result.append(contentsOf: split(first))
        }
        return result
    }

    /// 停止時: 残っている保留piece全部を、今あるturnsだけで分割して出す。
    public mutating func flush() -> [AlignedPiece] {
        let all = pending
        pending.removeAll()
        return all.flatMap { split($0) }
    }

    /// pieceのrunをturnの重なりで話者付けし、連続する同一話者runをまとめてAlignedPieceにする。
    private func split(_ piece: AlignerInput) -> [AlignedPiece] {
        guard !piece.text.isEmpty else { return [] }

        let runs =
            piece.runs.isEmpty
            ? [TranscriptRun(text: piece.text, startMS: piece.startMS, endMS: piece.endMS)]
            : piece.runs

        // runごとに最大重なり（>0）のturnを選ぶ。
        let rawMatches: [SpeakerTurn?] = runs.map { run in
            var best: SpeakerTurn?
            var bestOverlap: Int64 = 0
            for turn in turns {
                let overlap = min(run.endMS, turn.endMS) - max(run.startMS, turn.startMS)
                if overlap > 0, overlap > bestOverlap {
                    bestOverlap = overlap
                    best = turn
                }
            }
            return best
        }

        // 重なりが無いrunは直前runの話者を引き継ぎ、先頭なら直後の話者を遡って取る。
        var resolvedIDs: [String?] = rawMatches.map { $0?.localID }
        if let firstMatchedIndex = resolvedIDs.firstIndex(where: { $0 != nil }) {
            if firstMatchedIndex > 0 {
                for index in 0..<firstMatchedIndex {
                    resolvedIDs[index] = resolvedIDs[firstMatchedIndex]
                }
            }
            if firstMatchedIndex + 1 < resolvedIDs.count {
                for index in (firstMatchedIndex + 1)..<resolvedIDs.count where resolvedIDs[index]
                    == nil
                {
                    resolvedIDs[index] = resolvedIDs[index - 1]
                }
            }
        }
        // どのrunにも話者が付かなければ全てnilのまま。

        // 連続する同一話者（nilはnil同士でまとまる）のrunをまとめる。
        var alignedPieces: [AlignedPiece] = []
        var index = 0
        while index < runs.count {
            var end = index
            while end + 1 < runs.count, resolvedIDs[end + 1] == resolvedIDs[index] {
                end += 1
            }

            let groupRuns = runs[index...end]
            let text = groupRuns.map(\.text).joined()
            let groupID = resolvedIDs[index]

            var embedding: [Float]?
            if groupID != nil {
                for groupIndex in index...end {
                    if let turn = rawMatches[groupIndex] {
                        embedding = turn.embedding
                        break
                    }
                }
            }

            alignedPieces.append(
                AlignedPiece(
                    text: text,
                    startMS: groupRuns.first!.startMS,
                    endMS: groupRuns.last!.endMS,
                    confidence: piece.confidence,
                    localSpeaker: groupID,
                    embedding: embedding
                ))

            index = end + 1
        }

        return alignedPieces
    }
}
