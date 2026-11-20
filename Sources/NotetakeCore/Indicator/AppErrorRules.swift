import Foundation

public enum AppErrorKey {
    public static let daemon = "daemon"
    public static let polish = "polish"
    public static let loginItem = "loginItem"
    /// capture-daemonが応答していない、または新しい収録へ切り替えていない
    public static let captureDaemon = "captureDaemon"

    public static func capture(_ source: Source) -> String { "capture.\(source.rawValue)" }

    /// 取り込みが一定時間`retrying`のまま続いたsource。`capture`のkey（直近の失敗）とは別の原因なので分ける
    public static func captureRetrying(_ source: Source) -> String { "capture.\(source.rawValue).retrying" }

    /// serveが付けたkey。serveが再起動したらまとめて消せるよう、prefixで分ける
    public static func serve(_ key: String) -> String { "serve:\(key)" }
}

/// serveの帯。daemonの失敗が同時にあれば、別の帯にせず2行目の理由として持つ
public struct ServeBanner: Equatable, Sendable {
    public var text: String
    public var reason: String?

    public init(text: String, reason: String?) {
        self.text = text
        self.reason = reason
    }
}

/// sourceごとの`retrying`が続き始めた時刻。statusは変化した時にしか届かないので、
/// 10秒続いたかはstatusの到着ではなく時刻で決める。そのために開始時刻と理由を持つ
public struct CaptureRetryTracker: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var sinceMS: Int64
        public var reason: String?
    }

    fileprivate(set) var entries: [Source: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
}

/// appが受け取るものからErrorBookへの変化。AppModelはここを呼ぶだけにして、規則を表示から切り離す
public enum AppErrorRules {
    /// `retrying`が続いたら取り込めていないと見なす時間。短い再試行で警告を出さないため
    public static let retryingAlertMS: Int64 = 10_000

    public static func apply(event: Event, to book: inout ErrorBook, nowMS: Int64) {
        var tracker = CaptureRetryTracker()
        apply(event: event, to: &book, tracker: &tracker, nowMS: nowMS)
    }

    /// `tracker`は呼び出し側が持ち回る。毎回作り直すと、続いた時間を数えられない
    public static func apply(
        event: Event, to book: inout ErrorBook, tracker: inout CaptureRetryTracker, nowMS: Int64
    ) {
        // eventが届くのはdaemonが生きている証拠なので、どのeventでもdaemonの失敗は治ったと見なす
        book.resolve(key: AppErrorKey.daemon)
        switch event {
        case .error(let message, let key):
            if let key {
                setServe(key: key, message: message, to: &book, nowMS: nowMS)
            } else {
                book.addTransient(message: message, nowMS: nowMS)
            }
        case .resolved(let key):
            book.resolve(key: AppErrorKey.serve(key))
        case .status(let status):
            applyCapture(status, to: &book, tracker: &tracker, nowMS: nowMS)
        default:
            break
        }
        promoteRetrying(&book, tracker: tracker, nowMS: nowMS)
    }

    /// `retryingAlertMS`続いたsourceをエラーにする。出た時刻は`retrying`の開始にして、気づくまでの遅れを隠さない。
    /// 呼ばれるたびに理由も更新する。すでに出ているものを消すのは`apply`だけ（治ったことはstatusでしか分からない）
    public static func promoteRetrying(_ book: inout ErrorBook, tracker: CaptureRetryTracker, nowMS: Int64) {
        for (source, entry) in tracker.entries where nowMS - entry.sinceMS >= retryingAlertMS {
            let message = entry.reason.map { "\(source.rawValue): 取り込めていません（\($0)）" }
                ?? "\(source.rawValue): 取り込めていません"
            book.set(key: AppErrorKey.captureRetrying(source), message: message, nowMS: entry.sinceMS)
        }
    }

    /// まだエラーにしていない`retrying`が10秒に届く時刻のうち最も早いもの。無ければnil
    public static func nextRetryingDeadlineMS(tracker: CaptureRetryTracker, nowMS: Int64) -> Int64? {
        tracker.entries.values
            .map { $0.sinceMS + retryingAlertMS }
            .filter { $0 > nowMS }
            .min()
    }

    private static func setServe(key: String, message: String, to book: inout ErrorBook, nowMS: Int64) {
        guard var summary = ServeErrorSummary.text(forKey: key) else {
            book.set(key: AppErrorKey.serve(key), message: message, nowMS: nowMS)
            return
        }
        if ErrorText.isOutOfSpace(message) {
            summary += "（ディスクの空きがありません）"
        }
        book.set(key: AppErrorKey.serve(key), summary: summary, detail: message, nowMS: nowMS)
    }

    /// 収録していないstatusは、全sourceのエラーが治った扱いになる。
    /// 収録中でcaptureが無い、またはsourceが載っていないstatusは、serveの再起動や引き継ぎの直後で、
    /// 治ったのか分からないので今の表示を変えない
    private static func applyCapture(
        _ status: StatusEvent, to book: inout ErrorBook, tracker: inout CaptureRetryTracker, nowMS: Int64
    ) {
        guard status.recording else {
            book.resolve(key: AppErrorKey.captureDaemon)
            for source in Source.allCases {
                book.resolve(key: AppErrorKey.capture(source))
                book.resolve(key: AppErrorKey.captureRetrying(source))
            }
            tracker = CaptureRetryTracker()
            return
        }
        if let capture = status.capture {
            let daemonReason = capture.lazy.compactMap(\.reason).first {
                $0 == CaptureActualWatcher.unresponsiveReason || $0 == CaptureActualWatcher.notSwitchedReason
            }
            if let daemonReason {
                book.set(key: AppErrorKey.captureDaemon, message: daemonReason, nowMS: nowMS)
            } else {
                book.resolve(key: AppErrorKey.captureDaemon)
            }
        }
        for source in Source.allCases {
            guard let captured = status.capture?.first(where: { $0.source == source }) else { continue }
            if let lastError = captured.lastError {
                book.set(key: AppErrorKey.capture(source), message: "\(source.rawValue): \(lastError)", nowMS: nowMS)
            } else {
                book.resolve(key: AppErrorKey.capture(source))
            }
            // capture-daemonの無応答と切り替え遅れは`captureDaemon`が伝えるので、sourceごとには重ねない
            let isDaemonReason = captured.reason == CaptureActualWatcher.unresponsiveReason
                || captured.reason == CaptureActualWatcher.notSwitchedReason
            if captured.state == .retrying, !isDaemonReason {
                let since = tracker.entries[source]?.sinceMS ?? nowMS
                tracker.entries[source] = .init(sinceMS: since, reason: captured.reason)
            } else {
                tracker.entries.removeValue(forKey: source)
                book.resolve(key: AppErrorKey.captureRetrying(source))
            }
        }
    }

    /// 新しいserveは自分のエラーを持ち直すので、前のserveのkeyは残さない
    public static func serveStarted(_ book: inout ErrorBook, nowMS: Int64) {
        book.resolveAll(withPrefix: "serve:", nowMS: nowMS)
    }

    /// serveが落ちている間のdaemonの失敗は同じ出来事なので、帯を2本に分けずserveの帯へ畳む。
    /// serveが動いている時は畳む相手がいないので、daemonの失敗は通常の帯のまま残す
    public static func banners(
        serve: IndicatorMessage?, entries: [ErrorEntry]
    ) -> (serve: ServeBanner?, entries: [ErrorEntry]) {
        guard let serve else { return (nil, entries) }
        let daemon = entries.first { $0.key == AppErrorKey.daemon }
        return (
            ServeBanner(text: serve.text, reason: daemon?.summary),
            entries.filter { $0.key != AppErrorKey.daemon }
        )
    }
}
