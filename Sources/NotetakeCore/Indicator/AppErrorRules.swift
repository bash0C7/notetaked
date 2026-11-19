import Foundation

public enum AppErrorKey {
    public static let daemon = "daemon"
    public static let polish = "polish"
    public static let loginItem = "loginItem"

    public static func capture(_ source: Source) -> String { "capture.\(source.rawValue)" }

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

/// appが受け取るものからErrorBookへの変化。AppModelはここを呼ぶだけにして、規則を表示から切り離す
public enum AppErrorRules {
    public static func apply(event: Event, to book: inout ErrorBook, nowMS: Int64) {
        // eventが届くのはdaemonが生きている証拠なので、どのeventでもdaemonの失敗は治ったと見なす
        book.resolve(key: AppErrorKey.daemon)
        switch event {
        case .error(let message, let key):
            if let key {
                book.set(key: AppErrorKey.serve(key), message: message, nowMS: nowMS)
            } else {
                book.addTransient(message: message, nowMS: nowMS)
            }
        case .resolved(let key):
            book.resolve(key: AppErrorKey.serve(key))
        case .status(let status):
            // captureが無い（収録していない）statusは、全sourceのエラーが治った扱いになる
            for source in Source.allCases {
                if let lastError = status.capture?.first(where: { $0.source == source })?.lastError {
                    book.set(
                        key: AppErrorKey.capture(source), message: "\(source.rawValue): \(lastError)", nowMS: nowMS)
                } else {
                    book.resolve(key: AppErrorKey.capture(source))
                }
            }
        default:
            break
        }
    }

    /// 新しいserveは自分のエラーを持ち直すので、前のserveのkeyは残さない
    public static func serveStarted(_ book: inout ErrorBook) {
        book.resolveAll(withPrefix: "serve:")
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
