import Foundation

/// Watchの録音が止まった理由。rawValueはsnake_case
public enum WatchHaltReason: String, Codable, Sendable, Equatable {
    case startFailed = "start_failed"
    case interrupted
    case routeChanged = "route_changed"
    case mediaServicesReset = "media_services_reset"
    case writeFailed = "write_failed"
    case noAudio = "no_audio"
    /// 連続録音の上限に達して自動で止めた。`halted`ではなく`auto_stopped`の行で記録される
    case autoStopped = "auto_stopped"

    public var displayText: String {
        switch self {
        case .startFailed: return "開始に失敗"
        case .interrupted: return "割り込み（通話・Siriなど）"
        case .routeChanged: return "音声の経路が変わった"
        case .mediaServicesReset: return "音声サービスの再起動"
        case .writeFailed: return "書き込みに失敗"
        case .noAudio: return "音声が途切れた"
        case .autoStopped: return "連続録音の上限で自動停止"
        }
    }
}
