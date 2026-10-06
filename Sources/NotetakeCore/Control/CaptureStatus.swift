import Foundation

/// statusイベントでappへ伝える、sourceごとの取り込みの状態
public struct CaptureStatus: Codable, Sendable, Equatable {
    public var source: Source
    public var state: CaptureSourceState
    /// `retrying`の理由
    public var reason: String?

    public init(source: Source, state: CaptureSourceState, reason: String? = nil) {
        self.source = source
        self.state = state
        self.reason = reason
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
        /// sourceごとの新しい書き込みや変換の失敗
        public var errors: [String] = []
    }

    private var last: Snapshot?
    private var fellBack = false
    private var reportedErrors: [Source: String] = [:]
    /// 実状態のprefixが収録中の収録と食い違い始めた時刻
    private var mismatchSince: Int64?

    public init() {}

    /// 新しい収録を始める。失敗の記憶と食い違いの計時は消す。入力機器の固定が外れたかは収録をまたいで続くため残す。
    /// `keepingSnapshot`がtrueなら（区切り）前回のsnapshotを残し、同じ表示を重ねて伝えない。
    /// falseなら（開始と引き継ぎ）最初の実状態を必ず伝える
    public mutating func beginRecording(keepingSnapshot: Bool) {
        reportedErrors = [:]
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
                            CaptureStatus(source: $0, state: .retrying, reason: Self.notSwitchedReason)
                        },
                        micInput: last?.micInput))
            }
            mismatchSince = nil
            let mic = actual.sources.first { $0.source == .mic }
            snapshot = Snapshot(
                statuses: sources.map { source in
                    let status = actual.sources.first { $0.source == source }
                    return CaptureStatus(source: source, state: status?.state ?? .off, reason: status?.reason)
                },
                micInput: mic?.input)
            let micFellBack = mic?.fellBackFromPinned ?? false
            changes.inputReset = micFellBack && !fellBack
            fellBack = micFellBack
            for status in actual.sources {
                guard let error = status.lastError, reportedErrors[status.source] != error else { continue }
                reportedErrors[status.source] = error
                changes.errors.append("\(status.source.rawValue): \(error)")
            }
        } else {
            mismatchSince = nil
            snapshot = Snapshot(
                statuses: sources.map {
                    CaptureStatus(source: $0, state: .retrying, reason: Self.unresponsiveReason)
                },
                micInput: last?.micInput)
        }
        if snapshot != last {
            changes.snapshot = snapshot
            last = snapshot
        }
        return changes
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
