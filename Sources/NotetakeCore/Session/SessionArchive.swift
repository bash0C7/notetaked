import Foundation

public enum SessionArchiveError: Error, Equatable {
    /// 収録中の収録は、確定処理の取り込みも改名もまとめるもできない
    case recording(String)
    case missingTimed(String)
    /// `speakers.json`が無い、または従来の形式で、確定済みの収録ではない
    case notFinalized(String)
    case unknownSpeaker(String)
}

/// 出力ディレクトリへの書き込みの唯一の入口。`final.md`を作る関数もここに1つだけある。
/// 収録中の1つの収録は`SessionStore`の開いたhandleへ書き、それ以外の収録への書き込みは、
/// 待ち合わせを挟まない同期の処理で行う。このため確定処理の取り込み、改名、まとめるは、
/// 他の書き込みと入れ違わずに最後まで進む
public actor SessionArchive {
    public struct ImportOutcome: Sendable {
        public var plan: FinalizeImportPlan
        public var event: FinalizedEvent
        /// 同じ回の`finalized`が既にあり、追記を飛ばした
        public var skipped: Bool
    }

    private struct CachedSpan {
        var modified: Date
        var size: Int
        var span: SessionSpan?
    }

    private let timeZone: TimeZone
    private var current: (store: SessionStore, directory: URL)?
    private var spanCache: [URL: CachedSpan] = [:]

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public var currentPrefix: String? { current?.store.prefix }

    // MARK: - 収録中の収録

    /// 収録を始める。以後`appendLive`はこの収録へ書く
    public func begin(prefix: String, in directory: URL) {
        current = (SessionStore(directory: directory, prefix: prefix), directory)
    }

    /// 収録中の収録の`timed.jsonl`へ足す。mac発話の本文は`live.txt`にも足す
    public func appendLive(_ record: Record) async throws {
        guard let current else { throw SessionArchiveError.recording("収録していません") }
        try await current.store.append(record)
    }

    /// 収録を閉じる。`session_end`を足し、ここまでの発話で`final.md`を書く。収録していなければ何もしない
    public func endCurrent(endedMS: Int64) async throws {
        guard let current else { return }
        self.current = nil
        do {
            try await current.store.append(.sessionEnd(SessionEndRecord(ended: endedMS)))
        } catch {
            await current.store.close()
            throw error
        }
        await current.store.close()
        try renderFinal(prefix: current.store.prefix, in: current.directory)
    }

    /// 開始に失敗した収録を、`session_end`も`final.md`も書かずに閉じる
    public func abandonCurrent() async {
        guard let current else { return }
        self.current = nil
        await current.store.close()
    }

    // MARK: - 収録ごとの書き込み

    public func readRecords(prefix: String, in directory: URL) throws -> [Record] {
        let url = SessionFiles.timedURL(prefix: prefix, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionArchiveError.missingTimed(prefix)
        }
        // 電源断などで壊れたbyteがあっても、読める行を使う
        return SessionTranscript.records(timedText: String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    /// `timed.jsonl`から`final.md`を作り直す。`final.md`を作る唯一の関数
    public func renderFinal(prefix: String, in directory: URL) throws {
        let url = SessionFiles.timedURL(prefix: prefix, directory: directory)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try AtomicFile.write(
            Data(SessionTranscript.markdown(timedText: text, timeZone: timeZone).utf8),
            to: SessionFiles.finalURL(prefix: prefix, directory: directory))
    }

    /// 収録中でない収録へ記録を足し、`final.md`を作り直す。遅れて届いたpeerの発話に使う
    public func appendAndRender(_ records: [Record], prefix: String, in directory: URL) throws {
        guard prefix != currentPrefix else { throw SessionArchiveError.recording(prefix) }
        try TimedFile.append(records, to: SessionFiles.timedURL(prefix: prefix, directory: directory))
        try renderFinal(prefix: prefix, in: directory)
    }

    /// どの収録にも入らない発話を`orphans.jsonl`へ足す
    public func appendOrphan(_ segment: Segment, in directory: URL) throws {
        try TimedFile.append([.segment(segment)], to: directory.appendingPathComponent("orphans.jsonl"))
    }

    // MARK: - 確定処理

    /// 確定処理の結果を取り込む。何度行っても同じ結果になる。
    /// `speakers.json`、`timed.jsonl`への追記（1回の書き込み）、`final.md`の順に書く。
    /// 同じ回の`finalized`が`timed.jsonl`に既にあれば追記を飛ばし、残りだけをやり直す
    public func importFinalize(
        result: FinalizeResult, info: CaptureSessionInfo, prefix: String, receivedAt: Int64
    ) throws -> ImportOutcome {
        guard prefix != currentPrefix else { throw SessionArchiveError.recording(prefix) }
        let directory = URL(fileURLWithPath: info.outputDirectory)
        let records = try readRecords(prefix: prefix, in: directory)
        let speakersURL = SpeakersFile.url(prefix: prefix, directory: directory)
        let plan = FinalizeImport.plan(
            result: result, info: info, prefix: prefix, previous: try SpeakersFile.read(from: speakersURL),
            receivedAt: receivedAt)
        let skipped = FinalizeImport.isImported(run: result.run, in: records)
        let speakers = plan.speakers.reconciled(with: skipped ? records : records + plan.records)
        try speakers.write(to: speakersURL)
        if !skipped {
            try TimedFile.append(plan.records, to: SessionFiles.timedURL(prefix: prefix, directory: directory))
        }
        try renderFinal(prefix: prefix, in: directory)
        return ImportOutcome(
            plan: plan,
            event: FinalizedEvent(prefix: prefix, run: result.run, speakers: speakers.speakers.map(SpeakerSummary.init)),
            skipped: skipped)
    }

    /// 確定済みの収録の話者に名前を付ける。名前は`timed.jsonl`の`speaker_name`に回の番号を付けて残し、
    /// `speakers.json`と`final.md`を書き直す。空の名前は取り消し
    public func renameSpeaker(
        prefix: String, in directory: URL, device: String, id: String, name: String
    ) throws -> FinalizedEvent {
        try edit(prefix: prefix, in: directory, device: device) { run, file in
            guard let renamed = file.renaming(id: id, to: name) else { throw SessionArchiveError.unknownSpeaker(id) }
            return ([.speakerName(SpeakerNameRecord(speaker: id, name: name, run: run))], renamed)
        }
    }

    /// 確定済みの収録の話者`from`を`into`へまとめる。記録だけで直すので、生音声が無くてもできる
    public func mergeSpeakers(
        prefix: String, in directory: URL, device: String, from: String, into: String
    ) throws -> FinalizedEvent {
        try edit(prefix: prefix, in: directory, device: device) { run, file in
            guard file.speakers.contains(where: { $0.id == from }) else { throw SessionArchiveError.unknownSpeaker(from) }
            guard file.speakers.contains(where: { $0.id == into }), from != into else {
                throw SessionArchiveError.unknownSpeaker(into)
            }
            guard let merged = file.merging(from: from, into: into) else { throw SessionArchiveError.unknownSpeaker(from) }
            return ([.speakerMerge(SpeakerMergeRecord(run: run, from: from, into: into))], merged)
        }
    }

    /// 取り込みの後に途中で終わった収録の`speakers.json`と`final.md`を、`timed.jsonl`に合わせて直す
    public func repair(prefix: String, in directory: URL, device: String) throws -> FinalizedEvent? {
        guard prefix != currentPrefix else { throw SessionArchiveError.recording(prefix) }
        let records = try readRecords(prefix: prefix, in: directory)
        guard let run = FinalizedRuns.latestRun(in: records, device: device) else { return nil }
        let speakersURL = SpeakersFile.url(prefix: prefix, directory: directory)
        var summaries: [SpeakerSummary] = []
        if let file = try SpeakersFile.read(from: speakersURL), file.run == run {
            let repaired = file.reconciled(with: records)
            try repaired.write(to: speakersURL)
            summaries = repaired.speakers.map(SpeakerSummary.init)
        }
        try renderFinal(prefix: prefix, in: directory)
        return FinalizedEvent(prefix: prefix, run: run, speakers: summaries)
    }

    private func edit(
        prefix: String, in directory: URL, device: String,
        change: (_ run: Int, _ file: SpeakersFile) throws -> (records: [Record], file: SpeakersFile)
    ) throws -> FinalizedEvent {
        guard prefix != currentPrefix else { throw SessionArchiveError.recording(prefix) }
        let records = try readRecords(prefix: prefix, in: directory)
        let speakersURL = SpeakersFile.url(prefix: prefix, directory: directory)
        guard let run = FinalizedRuns.latestRun(in: records, device: device),
            let file = try SpeakersFile.read(from: speakersURL), file.run == run
        else {
            throw SessionArchiveError.notFinalized(prefix)
        }
        let edited = try change(run, file)
        try TimedFile.append(edited.records, to: SessionFiles.timedURL(prefix: prefix, directory: directory))
        try edited.file.write(to: speakersURL)
        try renderFinal(prefix: prefix, in: directory)
        return FinalizedEvent(prefix: prefix, run: run, speakers: edited.file.speakers.map(SpeakerSummary.init))
    }

    // MARK: - 収録の一覧

    /// 出力ディレクトリの`*.timed.jsonl`から収録の一覧を作る。更新時刻とサイズが変わったファイルだけ読み直す。
    /// 収録中の収録は`endMS`をnilにする
    public func sessions(in directory: URL) -> [SessionSpan] {
        let suffix = ".timed.jsonl"
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var spans: [SessionSpan] = []
        var seen: Set<URL> = []
        for url in urls where url.lastPathComponent.hasSuffix(suffix) {
            seen.insert(url)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if let cached = spanCache[url], cached.modified == modified, cached.size == size {
                if let span = cached.span { spans.append(span) }
                continue
            }
            let prefix = String(url.lastPathComponent.dropLast(suffix.count))
            let span = (try? Data(contentsOf: url)).flatMap {
                SessionSpanReader.span(prefix: prefix, records: SessionTranscript.records(timedText: String(decoding: $0, as: UTF8.self)))
            }
            spanCache[url] = CachedSpan(modified: modified, size: size, span: span)
            if let span { spans.append(span) }
        }
        spanCache = spanCache.filter { seen.contains($0.key) }
        if let currentPrefix, let index = spans.firstIndex(where: { $0.prefix == currentPrefix }) {
            spans[index].endMS = nil
        }
        return spans.sorted { $0.startMS < $1.startMS }
    }
}

public enum SessionSpanReader {
    /// 先頭の`session`の記録の`started`が開始。終了は`session_end`の`ended`で、無い収録（従来の収録と、
    /// 終了の記録を書く前に止まった収録）は全発話の`end + clock_offset_ms`の最大値、それも無ければ開始。
    /// `session`の記録が無ければnil
    public static func span(prefix: String, records: [Record]) -> SessionSpan? {
        guard
            let startMS = records.lazy.compactMap({ record -> Int64? in
                if case .session(let session) = record { return session.started }
                return nil
            }).first
        else { return nil }
        let ended = records.compactMap { record -> Int64? in
            if case .sessionEnd(let end) = record { return end.ended }
            return nil
        }.max()
        let segmentEnd = records.compactMap { record -> Int64? in
            if case .segment(let segment) = record { return segment.end + segment.clockOffsetMS }
            return nil
        }.max()
        return SessionSpan(prefix: prefix, startMS: startMS, endMS: ended ?? segmentEnd ?? startMS)
    }
}
