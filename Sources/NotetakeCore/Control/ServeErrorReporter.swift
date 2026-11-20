import Foundation

/// serveが失敗を報告する操作。エラーのkeyと回復の対応を、呼び出し側に分岐を持たせずここで決める
public enum ServeOperation: Equatable, Sendable {
    case desiredState
    case startRecording
    case appendLive
    case appendPeerOther
    case appendOrphan
    case startPeerListener
    case liveTranscription(Source)
    case finalize(prefix: String)

    public var errorKey: String {
        switch self {
        case .desiredState: return "desired"
        case .startRecording: return "recording.start"
        case .appendLive: return "archive.live"
        case .appendPeerOther: return "peer.other"
        case .appendOrphan: return "peer.orphan"
        case .startPeerListener: return "peer.listener"
        case .liveTranscription(let source): return "live.\(source.rawValue)"
        case .finalize(let prefix): return "final.\(prefix)"
        }
    }

    /// 収録が終わったら、その収録のprocessの失敗は意味を失うので消す。
    /// 収録の開始、確定処理、望む状態、端末の受け付けは収録の外にあり、止めても治ったとは言えないので入れない
    public static func clearedWhenRecordingStops(sources: [Source]) -> [ServeOperation] {
        sources.map { .liveTranscription($0) } + [.appendLive]
    }
}

/// keyを持たない、操作の拒否の文言。appは10秒の一時表示として出すので、利用者が読める日本語にする
public enum ServeMessage {
    public static let alreadyRecording = "既に収録中です"
    public static let notRecording = "収録していません"

    public static func invalidCommand(line: String) -> String { "解釈できない指示です: \(line)" }

    public static func alreadyQueued(prefix: String) -> String { "\(prefix)は既に確定の順番待ちです" }
}

/// keyごとの、画面に出す日本語の要約。元の文言（英語の例外の説明など）は詳細として別に持つ
public enum ServeErrorSummary {
    public static func text(forKey key: String) -> String? {
        switch key {
        case "desired": return "取り込みの指示を読み書きできません"
        case "recording.start": return "収録を始められません"
        case "archive.live": return "収録の記録を書けません"
        case "peer.other": return "端末の発話をほかの収録へ書けません"
        case "peer.orphan": return "行き先の無い端末の発話を書けません"
        case "peer.listener": return "端末からの接続を待ち受けられません"
        default:
            if key.hasPrefix("live.") {
                return "\(key.dropFirst("live.".count))のライブの文字起こしが止まっています"
            }
            if key.hasPrefix("final.") {
                return "\(key.dropFirst("final.".count))の確定処理に失敗しています"
            }
            return nil
        }
    }
}

public struct ServeErrorReporter: Sendable {
    private var active = ActiveErrorKeys()

    public init() {}

    public mutating func failed(_ operation: ServeOperation, message: String) -> Event {
        active.fail(operation.errorKey)
        return .error(message, key: operation.errorKey)
    }

    /// エラー中だった操作の成功の時だけ`resolved`を返す。毎回の成功でeventを流さないため
    public mutating func succeeded(_ operation: ServeOperation) -> Event? {
        active.resolve(operation.errorKey) ? .resolved(key: operation.errorKey) : nil
    }
}
