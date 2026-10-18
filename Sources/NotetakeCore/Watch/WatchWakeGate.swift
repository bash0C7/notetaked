import Foundation

/// 小片を閉じるたびにiPhoneを起こす合図（`sendMessage`）を送るかの判定と、返事・失敗の記録の要否。
/// 時計は引数で渡す。録音・転送は合図の成否に依らないので、ここは判定だけを持つ
public struct WatchWakeGate: Sendable, Equatable {
    /// 合図どうしの最短の間。20秒の小片なら毎回送れる。小片が短くなっても起こしすぎない
    public static let minIntervalMS: Int64 = 10_000
    /// 返事もerrorも来ない合図は、この時間で失敗と見なす
    public static let replyTimeoutMS: Int64 = 30_000

    public enum Decision: Sendable, Equatable {
        case send(attempt: Int)
        case skipUnreachable
        case skipInFlight
        case skipTooSoon
    }

    /// appが記録に書くもの。`firstFailure`は`wake_failed`、`recovered`は`wake_recovered`（`value`に連続の失敗数）
    public enum Note: Sendable, Equatable {
        case none
        case firstFailure(detail: String)
        case recovered(failures: Int)
    }

    public private(set) var consecutiveFailures: Int = 0

    private var lastAttempt: Int = 0
    private var inFlight: (attempt: Int, sentAtMS: Int64)?
    private var lastSentAtMS: Int64?

    public init() {}

    public static func == (lhs: WatchWakeGate, rhs: WatchWakeGate) -> Bool {
        lhs.consecutiveFailures == rhs.consecutiveFailures
            && lhs.lastAttempt == rhs.lastAttempt
            && lhs.inFlight?.attempt == rhs.inFlight?.attempt
            && lhs.inFlight?.sentAtMS == rhs.inFlight?.sentAtMS
            && lhs.lastSentAtMS == rhs.lastSentAtMS
    }

    public mutating func decide(isReachable: Bool, nowMS: Int64) -> (decision: Decision, note: Note) {
        var note: Note = .none
        if let pending = inFlight, nowMS - pending.sentAtMS >= Self.replyTimeoutMS {
            inFlight = nil
            note = countFailure(detail: "reply timeout")
        }
        guard isReachable else { return (.skipUnreachable, note) }
        guard inFlight == nil else { return (.skipInFlight, note) }
        if let lastSentAtMS, nowMS - lastSentAtMS < Self.minIntervalMS {
            return (.skipTooSoon, note)
        }
        lastAttempt += 1
        inFlight = (lastAttempt, nowMS)
        lastSentAtMS = nowMS
        return (.send(attempt: lastAttempt), note)
    }

    /// どの`attempt`の返事でも、届いた証拠として連続の失敗を0に戻す
    public mutating func replied(attempt: Int, atMS: Int64) -> Note {
        if inFlight?.attempt == attempt { inFlight = nil }
        let failures = consecutiveFailures
        consecutiveFailures = 0
        return failures >= 1 ? .recovered(failures: failures) : .none
    }

    /// 返事待ちの`attempt`の時だけ数える。時間切れで数え済みの古い`attempt`のerrorは二重に数えない
    public mutating func failed(attempt: Int, atMS: Int64, detail: String) -> Note {
        guard inFlight?.attempt == attempt else { return .none }
        inFlight = nil
        return countFailure(detail: detail)
    }

    private mutating func countFailure(detail: String) -> Note {
        consecutiveFailures += 1
        return consecutiveFailures == 1 ? .firstFailure(detail: detail) : .none
    }
}
