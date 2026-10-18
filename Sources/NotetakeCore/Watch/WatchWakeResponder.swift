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
    /// つなぎ中（`.connecting`）は、起きてからこの時間まで待つ。Macが寝ている・圏外でも、毎回25秒taskを持たない
    public static let connectingGiveUpMS: Int64 = 20_000
    /// 残りがこれを超える間だけ、つなぎ中のtaskを持つ。streamを閉じて確定させる余裕を残すため
    public static let finishStreamsMinRemainingSeconds: Double = 10
    /// つなぎ中の保持を打ち切る残り。監視は1秒刻みなので、`finishStreamsMinRemainingSeconds`に余裕を足し、
    /// 打ち切って終える時点でもstreamを閉じて確定させられる（`finishAll`が飛ばされない）ようにする
    public static let connectingHoldMinRemainingSeconds: Double = finishStreamsMinRemainingSeconds + 3
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
        /// Macへ接続を試している最中（`.connecting`）。つなぎ中は諦めずに、期限の余裕まで待つ
        public var peerConnecting: Bool

        public init(
            intakeBacklog: Int, unackedSegments: Int, peerConnected: Bool, remainingSeconds: Double, nowMS: Int64,
            peerConnecting: Bool = false
        ) {
            self.peerConnecting = peerConnecting
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
            let holdMS =
                progress.peerConnecting && progress.remainingSeconds > Self.connectingHoldMinRemainingSeconds
                ? Self.connectingGiveUpMS : Self.peerGiveUpMS
            if progress.nowMS - wokeAtMS < holdMS { return false }
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
        case stopped, waitingToRetry
        /// browsing / connecting。その状態に入ってからの経過と、入った後にappが背面へ回った（suspendをまたいだ）か
        case attempting(ageMS: Int64, crossedSuspend: Bool)
        case connected(lastActivityAgeMS: Int64)
    }

    /// browsing / connectingがこれを超えて続いたら、止まっているものとして作り直す
    public static let attemptStaleAfterMS: Int64 = 5_000

    public enum Decision: Sendable, Equatable {
        case none, connectNow, reconnectNow
    }

    public static func onWake(_ link: Link) -> Decision {
        switch link {
        case .stopped: return .none
        case .attempting(let age, let crossed):
            return crossed || age > attemptStaleAfterMS ? .reconnectNow : .none
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
    case peerState = "peer_state"
    case wakeDecision = "wake_decision"
    case browseResult = "browse_result"
    case connectStarted = "connect_started"
    case connectReady = "connect_ready"
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

/// Mac再接続の計測（`detail`の書式）。実機のrelay-traceを機械で読むため、書式はここで固定する
extension RelayTraceRecord {
    public static func peerStateDetail(from: String, to: String, reason: String?) -> String {
        "\(from)->\(to)" + (reason.map { " reason=\($0)" } ?? "")
    }

    public static func wakeDecisionDetail(_ link: PeerWakePolicy.Link, _ decision: PeerWakePolicy.Decision) -> String {
        let linkText: String
        switch link {
        case .stopped: linkText = "link=stopped"
        case .waitingToRetry: linkText = "link=waitingToRetry"
        case .attempting(let age, let crossed):
            linkText = "link=attempting age_ms=\(age) crossed_suspend=\(crossed)"
        case .connected(let age): linkText = "link=connected age_ms=\(age)"
        }
        return "\(linkText) decision=\(decision)"
    }

    public static func browseResultDetail(count: Int, chosen: String?) -> String {
        "count=\(count) chosen=\(chosen ?? "none")"
    }

    /// `kind`は`browse`（発見した端点）か`direct`（前回つながった端点）
    public static func connectStartedDetail(endpoint: String, kind: String) -> String {
        "endpoint=\(endpoint) kind=\(kind)"
    }

    public static func connectReadyDetail(elapsedMS: Int64, interface: String?, kind: String) -> String {
        "elapsed_ms=\(elapsedMS) interface=\(interface ?? "none") kind=\(kind)"
    }
}

/// 再接続の逐次の手順。同時に2本の接続を持たない。
/// 保存した直前の端点があればそこへ直接つなぎ（時間制限つき）、失敗・時間切れならbrowseへ進む
public struct PeerReconnect: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle, direct, browsing, browseConnecting, connected
    }

    public enum Step: Sendable, Equatable {
        case connectDirect, startBrowse, connectBrowsed, scheduleBackoff, ignore
    }

    public private(set) var phase: Phase = .idle
    /// 直前に`.ready`になった端点を持っているか。直接接続が失敗したら捨てる（Macのport等が変わりうる）
    public private(set) var hasSavedEndpoint = false

    public init() {}

    public mutating func endpointSaved() { hasSavedEndpoint = true }

    /// 最初の探索・wakeの作り直し・backoff明けのすべて。進行中のものは呼び出し側が先にcancelする
    public mutating func start(allowDirect: Bool) -> Step {
        if allowDirect && hasSavedEndpoint {
            phase = .direct
            return .connectDirect
        }
        phase = .browsing
        return .startBrowse
    }

    /// 直接接続の失敗・時間切れ。直接接続中の時だけbrowseへ進む（古いcallbackは無視）
    public mutating func directFailed() -> Step {
        guard phase == .direct else { return .ignore }
        hasSavedEndpoint = false
        phase = .browsing
        return .startBrowse
    }

    /// browseが端点を見つけた。browse中の最初の1回だけつなぐ
    public mutating func browseFound() -> Step {
        guard phase == .browsing else { return .ignore }
        phase = .browseConnecting
        return .connectBrowsed
    }

    /// 直接・browse経由どちらでも`.ready`。以後の失敗は切断として扱う
    public mutating func ready() {
        phase = .connected
    }

    /// 接続の失敗・切断。直接接続中ならbrowseへ、それ以外はbackoffして作り直す
    public mutating func connectionFailed() -> Step {
        switch phase {
        case .direct: return directFailed()
        case .idle: return .ignore
        case .browsing, .browseConnecting, .connected:
            phase = .idle
            return .scheduleBackoff
        }
    }

    public mutating func stop() {
        phase = .idle
    }
}
