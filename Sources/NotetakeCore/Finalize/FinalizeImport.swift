import Foundation

public struct FinalizeImportPlan: Equatable, Sendable {
    /// `timed.jsonl`へ1回の書き込みで足す記録。確定版の発話、名前、`finalized`の順
    public var records: [Record]
    public var speakers: SpeakersFile
    /// 前回の名前を引き継いだ話者
    public var matches: [SpeakerMatch]
    /// 引き継げなかった話者の、最も近い前回の名前付きの話者。類似度の実測に使う
    public var closest: [SpeakerMatch]
}

/// 確定処理の結果（`FinalizeResult`）を、出力ディレクトリへ書く記録と`speakers.json`へ直す純粋関数
public enum FinalizeImport {
    /// `timed.jsonl`に同じ回の`finalized`の記録が既にあるか。あれば追記を飛ばす
    public static func isImported(run: Int, in records: [Record]) -> Bool {
        records.contains { record in
            if case .finalized(let finalized) = record { return finalized.run == run }
            return false
        }
    }

    /// - 話者には、その回の中で最初に話した順に`s1`、`s2`…を振る。発話の無い話者は含めない
    /// - 名前は、`previous`が同じ回なら（取り込みのやり直し）そのまま使い、別の回なら名前付きの話者と
    ///   声の特徴で対応させて引き継ぐ。`seq`は回の中の通し番号
    public static func plan(
        result: FinalizeResult, info: CaptureSessionInfo, prefix: String, previous: SpeakersFile?,
        receivedAt: Int64
    ) -> FinalizeImportPlan {
        var firstSpoken: [LocalSpeaker: Int64] = [:]
        for sourceResult in result.sources {
            for utterance in sourceResult.utterances {
                guard let id = utterance.speaker else { continue }
                let key = LocalSpeaker(source: sourceResult.source, id: id)
                firstSpoken[key] = min(firstSpoken[key] ?? .max, utterance.start)
            }
        }
        let globalIDs = SpeakerNumbering.assign(firstSpoken: firstSpoken)

        var speakers: [SpeakersFile.Speaker] = []
        for sourceResult in result.sources {
            for speaker in sourceResult.speakers {
                let key = LocalSpeaker(source: sourceResult.source, id: speaker.local)
                guard let id = globalIDs[key] else { continue }
                speakers.append(
                    SpeakersFile.Speaker(
                        id: id, source: sourceResult.source, speechSeconds: speaker.seconds,
                        excerpt: speaker.excerpt, firstStartMS: speaker.firstStartMS, centroid: speaker.centroid))
            }
        }
        speakers.sort { Self.number(of: $0.id) < Self.number(of: $1.id) }

        var matches: [SpeakerMatch] = []
        var closest: [SpeakerMatch] = []
        if let previous, previous.run == result.run {
            for index in speakers.indices {
                speakers[index].name = previous.speakers.first { $0.id == speakers[index].id }?.name
            }
        } else if let previous {
            let named = previous.speakers.filter { $0.name != nil && !$0.centroid.isEmpty }
            let current = Dictionary(
                uniqueKeysWithValues: speakers.filter { !$0.centroid.isEmpty }.map { ($0.id, $0.centroid) })
            let previousCentroids = Dictionary(uniqueKeysWithValues: named.map { ($0.id, $0.centroid) })
            matches = SpeakerMatcher.match(current: current, previous: previousCentroids)
            let matched = Set(matches.map(\.current))
            closest = SpeakerMatcher.closest(current: current, previous: previousCentroids).filter {
                !matched.contains($0.current)
            }
            for match in matches {
                guard let index = speakers.firstIndex(where: { $0.id == match.current }) else { continue }
                speakers[index].name = named.first { $0.id == match.previous }?.name
            }
        }

        var records: [Record] = []
        var seq = 0
        let ordered = result.sources.flatMap { sourceResult in
            sourceResult.utterances.map { (sourceResult.source, $0) }
        }.sorted { ($0.1.start, $0.0.rawValue) < ($1.1.start, $1.0.rawValue) }
        for (source, utterance) in ordered {
            seq += 1
            let tag = utterance.speaker.map { id -> SpeakerTag in
                let key = LocalSpeaker(source: source, id: id)
                return SpeakerTag(local: key.tag, global: globalIDs[key])
            }
            records.append(
                .segment(
                    Segment(
                        id: utterance.id, session: prefix, seq: seq, device: info.device,
                        deviceName: info.deviceName,
                        owner: OwnerLabel.label(for: source, configuredOwner: info.owner), platform: .mac,
                        source: source, input: utterance.input, start: utterance.start, end: utterance.end,
                        text: utterance.text, confidence: utterance.confidence, levelDBFS: utterance.levelDBFS,
                        speaker: tag, clockOffsetMS: 0, receivedAt: receivedAt, pass: .final, run: result.run)))
        }
        for speaker in speakers {
            guard let name = speaker.name else { continue }
            records.append(.speakerName(SpeakerNameRecord(speaker: speaker.id, name: name, run: result.run)))
        }
        records.append(
            .finalized(
                FinalizedRecord(run: result.run, device: info.device, sources: result.sources.map(\.source))))

        return FinalizeImportPlan(
            records: records, speakers: SpeakersFile(run: result.run, speakers: speakers), matches: matches,
            closest: closest)
    }

    private static func number(of id: String) -> Int {
        Int(id.dropFirst()) ?? .max
    }
}
