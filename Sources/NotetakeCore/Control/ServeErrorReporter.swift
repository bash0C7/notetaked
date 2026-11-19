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
