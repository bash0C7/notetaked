import Foundation

/// `notetaked finalize`が生音声ディレクトリへ書く`finalize.json`。時刻は壁時計のepoch ms
public struct FinalizeResult: Codable, Equatable, Sendable {
    public var run: Int
    public var sources: [FinalizeSourceResult]

    public init(run: Int, sources: [FinalizeSourceResult]) {
        self.run = run
        self.sources = sources
    }
}

public struct FinalizeSourceResult: Codable, Equatable, Sendable {
    public var source: Source
    public var utterances: [FinalizeUtterance]
    public var speakers: [FinalizeSpeaker]

    public init(source: Source, utterances: [FinalizeUtterance], speakers: [FinalizeSpeaker]) {
        self.source = source
        self.utterances = utterances
        self.speakers = speakers
    }
}

public struct FinalizeUtterance: Codable, Equatable, Sendable {
    /// 結果ファイルに持たせるため、取り込みを何度行っても同じ発話は同じidになる
    public var id: UUID
    /// 話者分離がsourceの中で付けたid（`S1`）。話者の区間が無ければnil
    public var speaker: String?
    public var start: Int64
    public var end: Int64
    public var text: String
    public var confidence: Double?
    public var levelDBFS: Double
    public var input: InputDevice

    enum CodingKeys: String, CodingKey {
        case id
        case speaker
        case start
        case end
        case text
        case confidence
        case levelDBFS = "level_dbfs"
        case input
    }

    public init(
        id: UUID, speaker: String?, start: Int64, end: Int64, text: String, confidence: Double?,
        levelDBFS: Double, input: InputDevice
    ) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.levelDBFS = levelDBFS
        self.input = input
    }
}

public struct FinalizeSpeaker: Codable, Equatable, Sendable {
    public var local: String
    public var seconds: Double
    public var excerpt: String
    public var firstStartMS: Int64
    public var centroid: [Float]

    enum CodingKeys: String, CodingKey {
        case local
        case seconds
        case excerpt
        case firstStartMS = "first_start_ms"
        case centroid
    }

    public init(local: String, seconds: Double, excerpt: String, firstStartMS: Int64, centroid: [Float]) {
        self.local = local
        self.seconds = seconds
        self.excerpt = excerpt
        self.firstStartMS = firstStartMS
        self.centroid = centroid
    }
}

public enum FinalizeAssemblyError: Error, Equatable {
    /// `.meta.jsonl`にanchorが無く、sampleを壁時計へ直せない
    case noAnchor(Source)
}

/// 1つのsourceの文字起こし、話者の区間、時刻の対応から、`FinalizeSourceResult`を組み立てる純粋関数
public enum FinalizeAssembler {
    /// 発話の抜粋の最大文字数
    public static let excerptLength = 40

    /// - `phrases`と`turns`の時刻は音声の先頭からのms。sample番号へ直し、`timeline`で壁時計と入力機器を求める
    /// - `levelDBFS`は発話のsample範囲の音量を返す
    /// - systemの入力機器は`InputDevice.system`。micでdevice行が無ければ`fallbackInput`
    public static func sourceResult(
        source: Source,
        phrases: [TranscribedPhrase],
        turns: [SpeakerTurn],
        centroids: [String: [Float]],
        timeline: CaptureTimeline,
        levelDBFS: (Range<Int64>) -> Double,
        fallbackInput: InputDevice,
        makeID: () -> UUID = { UUID() }
    ) throws -> FinalizeSourceResult {
        var utterances: [FinalizeUtterance] = []
        for item in SpeakerAssigner.assign(phrases: phrases, turns: turns) {
            let startSample = CapturePCM.samples(forMS: item.startMS)
            let endSample = max(startSample, CapturePCM.samples(forMS: item.endMS))
            guard let start = timeline.ms(atSample: startSample), let end = timeline.ms(atSample: endSample) else {
                throw FinalizeAssemblyError.noAnchor(source)
            }
            let input =
                source == .system
                ? InputDevice.system : (timeline.device(atSample: startSample) ?? fallbackInput)
            utterances.append(
                FinalizeUtterance(
                    id: makeID(), speaker: item.speaker, start: start, end: max(start, end), text: item.text,
                    confidence: item.confidence, levelDBFS: levelDBFS(startSample..<endSample), input: input))
        }

        var speakers: [FinalizeSpeaker] = []
        var seen: Set<String> = []
        for utterance in utterances {
            guard let local = utterance.speaker, seen.insert(local).inserted else { continue }
            let seconds = turns.filter { $0.speaker == local }.reduce(0.0) {
                $0 + Double($1.endMS - $1.startMS) / 1000
            }
            speakers.append(
                FinalizeSpeaker(
                    local: local, seconds: seconds, excerpt: String(utterance.text.prefix(excerptLength)),
                    firstStartMS: utterance.start, centroid: centroids[local] ?? []))
        }
        return FinalizeSourceResult(source: source, utterances: utterances, speakers: speakers)
    }
}

extension CaptureSessionPaths {
    /// 確定処理の結果。`notetaked finalize`が書く
    public static func finalizeResultURL(sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("finalize.json")
    }

    /// 自動の再試行で失敗した回数。serveが書く
    public static func finalizeAttemptsURL(sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("finalize-attempts")
    }
}

public enum OwnerLabel {
    /// systemの発話に付く既定のラベル
    public static let remote = "リモート"

    public static func label(for source: Source, configuredOwner: String) -> String {
        source == .system ? remote : configuredOwner
    }
}
