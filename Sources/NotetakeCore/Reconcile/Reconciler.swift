import Foundation

/// record列を畳み込み、device横断でsegをutteranceへ統合する純粋な状態機械。
/// I/Oを持たず、同じrecord列を与えれば常に同じ結果になる（`timed.jsonl`から`fold`で再構成できる）。
public struct Reconciler: Sendable {
    public struct Config: Sendable {
        public var overlapRatio: Double = 0.5
        public var toleranceMS: Int64 = 1000
        public var textThreshold: Double = 0.5
        public init() {}
    }

    private var config: Config
    public private(set) var utterances: [Utterance] = []          // start昇順
    public private(set) var speakerNames: [String: String] = [:]  // 話者id → 名前
    /// まとめた話者の行き先（`from` → `into`）
    private var mergedInto: [String: String] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 1 recordを適用し、追加・変更されたutteranceを返す
    @discardableResult
    public mutating func apply(_ record: Record) -> [Utterance] {
        switch record {
        case .session, .device, .sessionEnd, .finalized:
            return []
        case .speakerName(let rename):
            return applySpeakerName(rename)
        case .speakerMerge(let merge):
            return applySpeakerMerge(merge)
        case .segment(let seg):
            return applySegment(seg)
        }
    }

    /// (device, source)の組ごとに、`finalized`の記録がある最新の回の確定版の発話を使い、暫定版と古い回の
    /// 発話を無視する。確定版の無い組は暫定版を使う。名前とまとめは、使っている回の記録だけを当てる
    public static func fold(_ records: [Record], config: Config = Config()) -> [Utterance] {
        let runs = FinalizedRuns(records: records)
        var reconciler = Reconciler(config: config)
        for record in records where runs.includes(record) {
            reconciler.apply(record)
        }
        return reconciler.utterances
    }

    // MARK: - speaker_name

    /// 空の名前は名前の取り消しで、表示は既定の名前（「話者1」等）へ戻る
    private mutating func applySpeakerName(_ rename: SpeakerNameRecord) -> [Utterance] {
        let id = resolve(rename.speaker)
        let name = rename.name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames[id] = name.isEmpty ? nil : name
        var changed: [Utterance] = []
        for i in utterances.indices where utterances[i].speakerID == id {
            utterances[i].speaker = label(speakerID: id, ownerLabel: utterances[i].ownerLabel)
            changed.append(utterances[i])
        }
        return changed
    }

    // MARK: - speaker_merge

    /// `from`の発話を`into`へ移す。`into`に名前が無ければ`from`の名前を引き継ぐ
    private mutating func applySpeakerMerge(_ merge: SpeakerMergeRecord) -> [Utterance] {
        let from = resolve(merge.from)
        let into = resolve(merge.into)
        guard from != into else { return [] }
        mergedInto[from] = into
        if speakerNames[into] == nil {
            speakerNames[into] = speakerNames[from]
        }
        speakerNames[from] = nil
        var changed: [Utterance] = []
        for i in utterances.indices where utterances[i].speakerID == from || utterances[i].speakerID == into {
            utterances[i].speakerID = into
            utterances[i].speaker = label(speakerID: into, ownerLabel: utterances[i].ownerLabel)
            changed.append(utterances[i])
        }
        return changed
    }

    private func resolve(_ id: String) -> String {
        var current = id
        while let next = mergedInto[current] {
            current = next
        }
        return current
    }

    // MARK: - segment

    private mutating func applySegment(_ seg: Segment) -> [Utterance] {
        guard !utterances.contains(where: { $0.sources.contains(seg.id) }) else { return [] }
        guard !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let start = seg.start + seg.clockOffsetMS
        let end = seg.end + seg.clockOffsetMS

        guard let matchIndex = bestCandidateIndex(for: seg, start: start, end: end) else {
            let utterance = makeUtterance(from: seg, start: start, end: end)
            insertSorted(utterance)
            return [utterance]
        }

        let merged = merge(seg: seg, into: utterances[matchIndex], start: start, end: end)
        utterances[matchIndex] = merged
        utterances.sort { $0.start < $1.start }
        return [merged]
    }

    /// devicesにseg.deviceを含まないutteranceのうち、時間重なりとtext類似度の両方を満たすものを探し、
    /// 複数あれば重なり幅（`min(end) - max(start)`）が最大のものを返す（同点は`utterances`の先頭側を優先）。
    private func bestCandidateIndex(for seg: Segment, start: Int64, end: Int64) -> Int? {
        var bestIndex: Int?
        var bestOverlap = Int64.min
        for (index, utterance) in utterances.enumerated() {
            guard !utterance.devices.contains(seg.device) else { continue }

            let overlapWithTolerance = min(utterance.end, end) + config.toleranceMS - max(utterance.start, start)
            let minDuration = max(1, min(utterance.end - utterance.start, end - start))
            guard Double(overlapWithTolerance) >= config.overlapRatio * Double(minDuration) else { continue }
            guard TextSimilarity.bigramDice(utterance.text, seg.text) >= config.textThreshold else { continue }

            let overlap = min(utterance.end, end) - max(utterance.start, start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func makeUtterance(from seg: Segment, start: Int64, end: Int64) -> Utterance {
        var utterance = Utterance(
            id: seg.id,
            start: start,
            end: end,
            speakerID: seg.speaker?.global.map(resolve),
            speaker: "",
            text: seg.text,
            confidence: seg.confidence,
            source: seg.source,
            platform: seg.platform,
            ownerLabel: seg.owner,
            input: seg.input.name,
            sources: [seg.id],
            devices: [seg.device],
            direction: seg.direction,
            locationInput: seg.input.name,
            locationPlatform: seg.platform,
            locationSource: seg.source,
            locationDirection: seg.direction,
            locationLevelDBFS: seg.levelDBFS
        )
        utterance.speaker = label(speakerID: utterance.speakerID, ownerLabel: utterance.ownerLabel)
        return utterance
    }

    private func merge(seg: Segment, into utterance: Utterance, start: Int64, end: Int64) -> Utterance {
        var merged = utterance
        merged.sources.append(seg.id)
        merged.devices.append(seg.device)
        merged.start = min(merged.start, start)
        merged.end = max(merged.end, end)

        if textWins(seg: seg, overCurrent: merged) {
            merged.text = seg.text
            merged.confidence = seg.confidence
            merged.source = seg.source
            merged.platform = seg.platform
            merged.ownerLabel = seg.owner
            merged.input = seg.input.name
        }

        if let level = seg.levelDBFS,
           merged.locationLevelDBFS.map({ level > $0 }) ?? true
        {
            merged.locationLevelDBFS = level
            merged.locationInput = seg.input.name
            merged.locationPlatform = seg.platform
            merged.locationSource = seg.source
            merged.locationDirection = seg.direction
        }

        if let candidate = seg.direction,
           merged.direction.map({ candidate.confidence > $0.confidence }) ?? true
        {
            merged.direction = candidate
        }

        if merged.speakerID == nil {
            merged.speakerID = seg.speaker?.global.map(resolve)
        }
        merged.speaker = label(speakerID: merged.speakerID, ownerLabel: merged.ownerLabel)
        return merged
    }

    /// `(confidence ?? 0, priority(source), text.count)` の辞書順比較でsegが現在の採用本文より大きいか
    private func textWins(seg: Segment, overCurrent current: Utterance) -> Bool {
        let candidate = (seg.confidence ?? 0, Self.priority(seg.source), seg.text.count)
        let incumbent = (current.confidence ?? 0, Self.priority(current.source), current.text.count)
        if candidate.0 != incumbent.0 { return candidate.0 > incumbent.0 }
        if candidate.1 != incumbent.1 { return candidate.1 > incumbent.1 }
        return candidate.2 > incumbent.2
    }

    private static func priority(_ source: Source) -> Int {
        switch source {
        case .system: return 3
        case .mic: return 2
        case .watch: return 1
        }
    }

    private func label(speakerID: String?, ownerLabel: String) -> String {
        guard let speakerID else { return ownerLabel }
        return speakerNames[speakerID] ?? SpeakerLabel.defaultName(for: speakerID)
    }

    // MARK: - ordered insert

    /// start昇順を保って挿入する。同じstartでは既存（先に挿入済み）が先になる。
    private mutating func insertSorted(_ utterance: Utterance) {
        let index = utterances.firstIndex { $0.start > utterance.start } ?? utterances.count
        utterances.insert(utterance, at: index)
    }
}


extension Reconciler {
    /// 既存の`timed.jsonl`の記録を畳み込み、`device`のsegの最大の`seq`を返す。
    /// serveが収録を途中から引き継ぐ時に、表示と`seq`を続きから始めるために使う
    public static func restore(from records: [Record], device: String) -> (reconciler: Reconciler, lastSeq: Int) {
        var reconciler = Reconciler()
        var lastSeq = 0
        for record in records {
            reconciler.apply(record)
            if case .segment(let segment) = record, segment.device == device {
                lastSeq = max(lastSeq, segment.seq)
            }
        }
        return (reconciler, lastSeq)
    }
}
