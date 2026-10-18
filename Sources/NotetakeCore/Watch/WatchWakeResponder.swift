import Foundation

/// Watchの合図で背面に起こされたiPhoneが、background taskをいつ取り、いつ終えるかの判定。
/// background taskは1本だけ持つ（背面の残り時間はappで1つなので、2本目を取っても延びない）
public struct WatchWakeResponder: Sendable, Equatable {
    /// 最後の動き（合図・小片の受信・segの発行・ack）からこの間は終えない。
    /// WCSessionが続けて小片を渡す・Transcriberが確定を出す間を待つ
    public static let settleMS: Int64 = 3_000
    /// Macへつながらない時、起きてからこの時間で送信を諦める。
    /// Macが寝ている・圏外の時に毎回30秒起き続けて電池を使わないため
    public static let peerGiveUpMS: Int64 = 15_000
    /// `backgroundTimeRemaining`がこれ以下なら、仕事が残っていても終える
    public static let finishMarginSeconds: Double = 5

    public enum WakeAction: Sendable, Equatable {
        case foreground, beginTask, keepTask
    }

    public struct Progress: Sendable, Equatable {
        public var intakeBacklog: Int
        public var unackedSegments: Int
        public var peerConnected: Bool
        public var remainingSeconds: Double
        public var nowMS: Int64

        public init(
            intakeBacklog: Int, unackedSegments: Int, peerConnected: Bool, remainingSeconds: Double, nowMS: Int64
        ) {
            self.intakeBacklog = intakeBacklog
            self.unackedSegments = unackedSegments
            self.peerConnected = peerConnected
            self.remainingSeconds = remainingSeconds
            self.nowMS = nowMS
        }
    }

    public private(set) var holdsTask = false
    /// background taskを取るたびに増える。finishを`await`している間に別のtaskへ替わったかを見分ける
    public private(set) var taskGeneration = 0
    private var wokeAtMS: Int64 = 0
    private var lastActivityAtMS: Int64 = 0

    public init() {}

    public mutating func woke(appIsActive: Bool, atMS: Int64) -> WakeAction {
        wokeAtMS = atMS
        lastActivityAtMS = atMS
        if appIsActive { return .foreground }
        if holdsTask { return .keepTask }
        holdsTask = true
        taskGeneration += 1
        return .beginTask
    }

    public mutating func activity(atMS: Int64) {
        lastActivityAtMS = max(lastActivityAtMS, atMS)
    }

    public func shouldEnd(_ progress: Progress) -> Bool {
        guard holdsTask else { return false }
        if progress.remainingSeconds <= Self.finishMarginSeconds { return true }
        if progress.intakeBacklog > 0 { return false }
        if progress.nowMS - lastActivityAtMS < Self.settleMS { return false }
        if progress.unackedSegments > 0 {
            if progress.peerConnected { return false }
            if progress.nowMS - wokeAtMS < Self.peerGiveUpMS { return false }
        }
        return true
    }

    public enum FinalizeOutcome: Sendable, Equatable {
        /// 同じtaskのまま、新しい進み具合でも終えてよい
        case endNow
        /// finishの間に合図が来た。この監視は生かして、新しい仕事を待つ
        case keepMonitoring
        /// finishの間にtaskが終わった・別のtaskに替わった。この監視は新しいtaskを終えずに退く
        case taskReplaced
    }

    /// streamを閉じる（`await`で数秒〜十数秒かかる）前に`shouldEnd`が真になった監視が、戻った後に何をするか。
    /// 古い監視が、その間に取り直した新しいtaskと新しい小片の処理を終えてしまわないための判定。
    /// `startedGeneration`は閉じる前の`taskGeneration`、`progress`は戻った後に作り直したもの
    public func outcomeAfterFinalize(startedGeneration: Int, progress: Progress) -> FinalizeOutcome {
        guard holdsTask, taskGeneration == startedGeneration else { return .taskReplaced }
        return shouldEnd(progress) ? .endNow : .keepMonitoring
    }

    /// background taskを終える前に、5秒間引きを無視して`watch_status`を送る必要があるか。
    /// 間引きの待ちTaskはtaskを終えるとsuspendされ、Macに古い状態（未処理の件数など）が残るため。
    /// `updatedAtMS`だけの違いは変化と見なさない（送信側の変化判定と同じ）
    public static func shouldFlushStatus(
        current: WatchStatusSnapshot?, lastSent: WatchStatusSnapshot?, peerConnected: Bool
    ) -> Bool {
        guard peerConnected, let current else { return false }
        guard var normalized = Optional(current), let lastSent else { return true }
        normalized.updatedAtMS = lastSent.updatedAtMS
        return normalized != lastSent
    }

    /// 終えた時と期限切れの時
    public mutating func taskEnded() {
        holdsTask = false
    }
}

/// 起きた時の`PeerClient`。suspendの間は再接続のbackoff（最大30秒）とwatchdogの時計が止まっているので、
/// 待たずにつなぎ直す
public enum PeerWakePolicy {
    /// Macは接続中60秒ごとにpingを送る。それより長く何も受けていない接続はsuspendの間に切れたと見なす
    public static let staleAfterMS: Int64 = 75_000

    public enum Link: Sendable, Equatable {
        case stopped, browsingOrConnecting, waitingToRetry
        case connected(lastActivityAgeMS: Int64)
    }

    public enum Decision: Sendable, Equatable {
        case none, connectNow, reconnectNow
    }

    public static func onWake(_ link: Link) -> Decision {
        switch link {
        case .stopped, .browsingOrConnecting: return .none
        case .waitingToRetry: return .connectNow
        case .connected(let age): return age > staleAfterMS ? .reconnectNow : .none
        }
    }
}

public enum RelayTraceEvent: String, Codable, Sendable {
    case wakeMessage = "wake_message"
    case fileReceived = "file_received"
    case taskBegan = "task_began"
    case taskEnded = "task_ended"
    case taskExpired = "task_expired"
    case peerConnected = "peer_connected"
    case chunkFed = "chunk_fed"
    case segEnqueued = "seg_enqueued"
    case segAcked = "seg_acked"
    case listeningStarted = "listening_started"
    case listeningStopped = "listening_stopped"
}

/// 実機gate（R1〜R8）の計測の1行（JSON Lines）。`nil`の項目は出さない
public struct RelayTraceRecord: Codable, Sendable, Equatable {
    public var atMS: Int64
    public var event: RelayTraceEvent
    /// `active` / `inactive` / `background`
    public var appState: String?
    public var remainingSeconds: Double?
    public var device: String?
    public var session: String?
    public var index: Int?
    public var seq: Int?
    public var endAtMS: Int64?
    public var detail: String?

    public init(
        atMS: Int64, event: RelayTraceEvent, appState: String? = nil, remainingSeconds: Double? = nil,
        device: String? = nil, session: String? = nil, index: Int? = nil, seq: Int? = nil,
        endAtMS: Int64? = nil, detail: String? = nil
    ) {
        self.atMS = atMS
        self.event = event
        self.appState = appState
        self.remainingSeconds = remainingSeconds
        self.device = device
        self.session = session
        self.index = index
        self.seq = seq
        self.endAtMS = endAtMS
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case atMS = "at_ms"
        case event
        case appState = "app_state"
        case remainingSeconds = "remaining_s"
        case device, session, index, seq
        case endAtMS = "end_at_ms"
        case detail
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// 空行・壊れた行・未知の`event`の行は飛ばす。`WatchObsRecord.decodeLines`と同じくbyteの`\n`で割る
    public static func decodeLines(_ text: String) -> [RelayTraceRecord] {
        let decoder = JSONDecoder()
        return text.utf8.split(separator: 0x0A).compactMap { line in
            var bytes = Data(Array(line))
            if bytes.last == 0x0D { bytes.removeLast() }
            return try? decoder.decode(RelayTraceRecord.self, from: bytes)
        }
    }
}
