import Foundation

/// statusイベントでappへ伝える、sourceごとの取り込みの状態
public struct CaptureStatus: Codable, Sendable, Equatable {
    public var source: Source
    public var state: CaptureSourceState
    /// `retrying`の理由
    public var reason: String?
    /// 実状態にある直近の書き込みや変換の失敗。治れば消えるので、appはこれの有無で表示を出し入れする
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case source
        case state
        case reason
        case lastError = "last_error"
    }

    public init(source: Source, state: CaptureSourceState, reason: String? = nil, lastError: String? = nil) {
        self.source = source
        self.state = state
        self.reason = reason
        self.lastError = lastError
    }
}

/// serveが実状態のファイルを読むたびに、appへ伝える変化を求める
public struct CaptureActualWatcher: Sendable {
    /// capture-daemonは1秒ごとに書くため、これより古い実状態はcapture-daemonが動いていないと見なす
    public static let staleAfterMS: Int64 = 5_000
    public static let unresponsiveReason = "capture-daemonが応答していません"
    /// 実状態のprefixが収録中の収録に切り替わらないまま、この時間が過ぎたら切り替わっていないと見なす
    public static let switchTimeoutMS: Int64 = 5_000
    public static let notSwitchedReason = "capture-daemonが新しい収録へ切り替えていません"

    public struct Snapshot: Equatable, Sendable {
        public var statuses: [CaptureStatus]
        public var micInput: InputDevice?
    }

    public struct Changes: Equatable, Sendable {
        /// 前回から変わった時だけ入る
        public var snapshot: Snapshot?
        /// 固定した入力機器から既定の入力へ戻った
        public var inputReset = false
        /// 新しく起きた1度きりの失敗の通知。`<source>: <通知>`の形で、同じ通知は1度しか入らない
        public var notices: [String] = []
    }

    private var last: Snapshot?
    private var fellBack = false
    /// 実状態のprefixが収録中の収録と食い違い始めた時刻
    private var mismatchSince: Int64?
    /// この時刻以前の通知は伝えない。serveの再起動で、前のserveが伝えた通知を繰り返さないため。
    /// 収録の開始では上げない。収録を切り替える時にcapture-daemonが書き込み先を閉じる失敗が、開始の直前に起きうる
    private let noticesAfterMS: Int64
    /// sourceごとに、伝え終えた通知の時刻
    private var emittedNoticeAtMS: [Source: Int64] = [:]

    public init(startedAtMS: Int64 = 0) {
        noticesAfterMS = startedAtMS
    }

    /// 新しい収録を始める。食い違いの計時は消す。入力機器の固定が外れたかは収録をまたいで続くため残す。
    /// `keepingSnapshot`がtrueなら（区切り）前回のsnapshotを残し、同じ表示を重ねて伝えない。
    /// falseなら（開始と引き継ぎ）最初の実状態を必ず伝える
    public mutating func beginRecording(keepingSnapshot: Bool) {
        mismatchSince = nil
        if !keepingSnapshot {
            last = nil
        }
    }

    /// `prefix`は収録中の収録。別の収録を書いている実状態は、切り替えの途中なので`switchTimeoutMS`の間は無視する。
    /// それを過ぎても切り替わらなければ、各sourceを「再開待ち」にする
    public mutating func observe(
        _ actual: CaptureActualState?, prefix: String, sources: [Source], nowMS: Int64
    ) -> Changes {
        var changes = Changes()
        let snapshot: Snapshot
        if let actual, nowMS - actual.updated <= Self.staleAfterMS {
            if actual.prefix != prefix {
                // 区切りの直後は、capture-daemonが書き込み先を切り替えるまでの間だけ食い違う
                let since = mismatchSince ?? nowMS
                mismatchSince = since
                guard nowMS - since >= Self.switchTimeoutMS else { return changes }
                return onlyChanges(
                    replacing: Snapshot(
                        statuses: sources.map {
                            CaptureStatus(
                                source: $0, state: .retrying, reason: Self.notSwitchedReason,
                                lastError: lastError(of: $0))
                        },
                        micInput: last?.micInput))
            }
            mismatchSince = nil
            let mic = actual.sources.first { $0.source == .mic }
            snapshot = Snapshot(
                statuses: sources.map { source in
                    let status = actual.sources.first { $0.source == source }
                    return CaptureStatus(
                        source: source, state: status?.state ?? .off, reason: status?.reason,
                        lastError: status?.lastError)
                },
                micInput: mic?.input)
            for source in sources {
                guard let status = actual.sources.first(where: { $0.source == source }) else { continue }
                if let notice = status.notice, let at = status.noticeAtMS,
                    at > max(noticesAfterMS, emittedNoticeAtMS[source, default: 0])
                {
                    emittedNoticeAtMS[source] = at
                    changes.notices.append("\(source.rawValue): \(notice)")
                }
            }
            let micFellBack = mic?.fellBackFromPinned ?? false
            changes.inputReset = micFellBack && !fellBack
            fellBack = micFellBack
        } else {
            mismatchSince = nil
            snapshot = Snapshot(
                statuses: sources.map {
                    CaptureStatus(
                        source: $0, state: .retrying, reason: Self.unresponsiveReason, lastError: lastError(of: $0))
                },
                micInput: last?.micInput)
        }
        if snapshot != last {
            changes.snapshot = snapshot
            last = snapshot
        }
        return changes
    }

    /// 実状態が読めない間は、失敗が治ったのか分からない。治ったと見せないよう前回の失敗を残す
    private func lastError(of source: Source) -> String? {
        last?.statuses.first { $0.source == source }?.lastError
    }

    private mutating func onlyChanges(replacing snapshot: Snapshot) -> Changes {
        var changes = Changes()
        if snapshot != last {
            changes.snapshot = snapshot
            last = snapshot
        }
        return changes
    }
}
