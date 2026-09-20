import Foundation

/// record列を畳み込み、device横断でsegをutteranceへ統合する純粋な状態機械。
/// I/Oを持たず、同じrecord列を与えれば常に同じ結果になる（`timed.jsonl`から`fold`で再構成できる）。
public struct Reconciler: Sendable {
    public struct Config: Sendable {
        public var overlapRatio: Double = 0.5
        public var toleranceMS: Int64 = 1000
        public var textThreshold: Double = 0.5
        /// speakerが付かないsegについて、直前の同一device utteranceの話者を継承してよい最大の間隔（ms）（issue #8）
        public var speakerInheritanceGapMS: Int64 = 5_000
        public init() {}
    }

    private var config: Config
    public private(set) var utterances: [Utterance] = []          // start昇順
    public private(set) var speakerNames: [String: String] = [:]  // 大域id → 名前

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 1 recordを適用し、追加・変更されたutteranceを返す
    @discardableResult
    public mutating func apply(_ record: Record) -> [Utterance] {
        switch record {
        case .session, .device:
            return []
        case .speakerName(let rename):
            return applySpeakerName(rename)
        case .segment(let seg):
            return applySegment(seg)
        }
    }

    public static func fold(_ records: [Record], config: Config = Config()) -> [Utterance] {
        var reconciler = Reconciler(config: config)
        for record in records {
            reconciler.apply(record)
        }
        return reconciler.utterances
    }

    // MARK: - speaker_name

    private mutating func applySpeakerName(_ rename: SpeakerNameRecord) -> [Utterance] {
        speakerNames[rename.speaker] = rename.name
        var changed: [Utterance] = []
        for i in utterances.indices where utterances[i].speakerID == rename.speaker {
            utterances[i].speaker = label(speakerID: utterances[i].speakerID, ownerLabel: utterances[i].ownerLabel)
            changed.append(utterances[i])
        }
        return changed
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
            speakerID: seg.speaker?.global ?? inheritedSpeakerID(for: seg, start: start),
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

    /// speakerが付かないsegについて、同じdeviceの直前のutteranceの話者を、時間差が
    /// `config.speakerInheritanceGapMS`以内なら継承する。継承元が無い（そのdeviceの
    /// 最初の発話）場合や閾値を超える場合はnilのまま（呼び出し側がownerLabelにfallbackする）（issue #8）
    private func inheritedSpeakerID(for seg: Segment, start: Int64) -> String? {
        for utterance in utterances.reversed() where utterance.devices.contains(seg.device) {
            guard start - utterance.end <= config.speakerInheritanceGapMS else { return nil }
            return utterance.speakerID
        }
        return nil
    }

    // MARK: - fallback speaker resolution (second pass)

    /// 区切り/停止のタイミングで呼ぶ第二パス。`speakerID`が無くownerLabelへfallbackしている
    /// utteranceについて、直前・直後両方向の同一device utteranceを見て再解決する。
    /// `inheritedSpeakerID`（リアルタイム・過去方向のみ）はライブ表示用にそのまま残し、
    /// このメソッドはfinal.md再生成時にのみ別途呼ぶ（issue #8二次対応）
    public func resolveFallbackSpeakers() -> [Utterance] {
        var result = utterances
        for index in result.indices where result[index].speakerID == nil {
            guard let resolved = resolveFallbackSpeakerID(at: index) else { continue }
            result[index].speakerID = resolved
            result[index].speaker = label(speakerID: resolved, ownerLabel: result[index].ownerLabel)
        }
        return result
    }

    /// 直前・直後それぞれの同一device utteranceのspeakerIDが一致すればそれを採用、
    /// 片方のみ得られればそれを採用、無いか矛盾すればnil（呼び出し側がfallbackを維持する）
    private func resolveFallbackSpeakerID(at index: Int) -> String? {
        let target = utterances[index]
        let before = nearestBeforeSpeakerID(before: index, target: target)
        let after = nearestAfterSpeakerID(after: index, target: target)
        switch (before, after) {
        case let (b?, a?) where b == a:
            return b
        case let (b?, nil):
            return b
        case let (nil, a?):
            return a
        default:
            return nil
        }
    }

    /// `index`より前で同一deviceを持つ直近のutteranceを探し、時間差が
    /// `config.speakerInheritanceGapMS`以内ならそのspeakerIDを返す
    private func nearestBeforeSpeakerID(before index: Int, target: Utterance) -> String? {
        var i = index - 1
        while i >= 0 {
            let candidate = utterances[i]
            if candidate.devices.contains(where: target.devices.contains) {
                guard target.start - candidate.end <= config.speakerInheritanceGapMS else { return nil }
                return candidate.speakerID
            }
            i -= 1
        }
        return nil
    }

    /// `index`より後で同一deviceを持つ直近のutteranceを探し、時間差が
    /// `config.speakerInheritanceGapMS`以内ならそのspeakerIDを返す
    private func nearestAfterSpeakerID(after index: Int, target: Utterance) -> String? {
        var i = index + 1
        while i < utterances.count {
            let candidate = utterances[i]
            if candidate.devices.contains(where: target.devices.contains) {
                guard candidate.start - target.end <= config.speakerInheritanceGapMS else { return nil }
                return candidate.speakerID
            }
            i += 1
        }
        return nil
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
            merged.speakerID = seg.speaker?.global ?? inheritedSpeakerID(for: seg, start: start)
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
        return speakerNames[speakerID] ?? speakerID
    }

    // MARK: - ordered insert

    /// start昇順を保って挿入する。同じstartでは既存（先に挿入済み）が先になる。
    private mutating func insertSorted(_ utterance: Utterance) {
        let index = utterances.firstIndex { $0.start > utterance.start } ?? utterances.count
        utterances.insert(utterance, at: index)
    }
}
