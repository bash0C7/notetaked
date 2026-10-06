import Foundation

/// 収録ごとの確定処理の状態
public enum FinalizePhase: String, Codable, Sendable {
    /// 順番待ち
    case waiting
    case running
    case finalized
    /// 失敗した。`retryAt`に自動で再試行する
    case failed
    /// 自動の再試行を使い切った。手動の確定し直しはできる
    case gaveUp
}

/// `finalize_state` eventの中身。状態が変わるたびに、serveがappへ送る
public struct FinalizeStateEvent: Codable, Sendable, Equatable {
    public var prefix: String
    public var phase: FinalizePhase
    /// 確定済みの回
    public var run: Int?
    /// 進捗（`running`）または失敗の理由（`failed`、`gaveUp`）
    public var detail: String?
    /// 自動の再試行の予定時刻（epoch ms、`failed`）
    public var retryAt: Int64?

    enum CodingKeys: String, CodingKey {
        case prefix
        case phase
        case run
        case detail
        case retryAt = "retry_at"
    }

    public init(prefix: String, phase: FinalizePhase, run: Int? = nil, detail: String? = nil, retryAt: Int64? = nil) {
        self.prefix = prefix
        self.phase = phase
        self.run = run
        self.detail = detail
        self.retryAt = retryAt
    }
}

/// 話者の一覧の1行。声の特徴は含めない
public struct SpeakerSummary: Codable, Sendable, Equatable {
    public var id: String
    public var source: Source
    public var name: String?
    public var speechSeconds: Double
    public var excerpt: String

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case name
        case speechSeconds = "speech_seconds"
        case excerpt
    }

    public init(id: String, source: Source, name: String?, speechSeconds: Double, excerpt: String) {
        self.id = id
        self.source = source
        self.name = name
        self.speechSeconds = speechSeconds
        self.excerpt = excerpt
    }

    public init(_ speaker: SpeakersFile.Speaker) {
        self.init(
            id: speaker.id, source: speaker.source, name: speaker.name, speechSeconds: speaker.speechSeconds,
            excerpt: speaker.excerpt)
    }
}

/// `finalized` eventの中身。確定処理の取り込み、改名、まとめるのたびに、その時点の話者の一覧を送る
public struct FinalizedEvent: Codable, Sendable, Equatable {
    public var prefix: String
    public var run: Int
    public var speakers: [SpeakerSummary]

    public init(prefix: String, run: Int, speakers: [SpeakerSummary]) {
        self.prefix = prefix
        self.run = run
        self.speakers = speakers
    }
}
