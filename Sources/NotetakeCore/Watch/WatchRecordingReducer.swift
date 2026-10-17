import Foundation

/// Watchの録音が止まった理由。rawValueはsnake_case
public enum WatchHaltReason: String, Sendable, Equatable {
    case startFailed = "start_failed"
    case interrupted
    case routeChanged = "route_changed"
    case mediaServicesReset = "media_services_reset"
    case writeFailed = "write_failed"
    case noAudio = "no_audio"
}

public enum WatchRecordingPhase: Sendable, Equatable {
    case idle
    case recording(startedAtMS: Int64, lastBufferAtMS: Int64?)
    case halted(reason: WatchHaltReason, atMS: Int64, detail: String?)
}

public enum WatchRecordingEvent: Sendable, Equatable {
    case started(atMS: Int64)
    case startFailed(atMS: Int64, message: String)
    case bufferArrived(atMS: Int64)
    case stopped(atMS: Int64)
    case interruptionBegan(atMS: Int64)
    case interruptionEnded(atMS: Int64, shouldResume: Bool)
    case configurationChanged(atMS: Int64)
    case mediaServicesReset(atMS: Int64)
    case writeFailed(atMS: Int64, message: String)
    case becameActive(atMS: Int64)
}

public struct WatchRecordingDisplay: Sendable, Equatable {
    /// 停止ボタンを出すか
    public var isActive: Bool
    public var message: IndicatorMessage

    public init(isActive: Bool, message: IndicatorMessage) {
        self.isActive = isActive
        self.message = message
    }
}

public enum WatchRecordingReducer {
    /// bufferが途切れてからこの時間（ms）を超えたら音声が届いていないとみなす
    public static let noAudioHaltMS: Int64 = 5_000

    /// `queueDepth`はtapが積んで未処理のbuffer数。0より大きい間はtapが流れている証拠なので、
    /// MainActorがbufferを受けた時刻が古くてもstaleとみなさない
    public static func reduce(
        _ phase: WatchRecordingPhase, _ event: WatchRecordingEvent, queueDepth: Int = 0
    ) -> WatchRecordingPhase {
        if case .stopped = event { return .idle }

        switch phase {
        case .idle, .halted:
            switch event {
            case .started(let atMS):
                return .recording(startedAtMS: atMS, lastBufferAtMS: nil)
            case .startFailed(let atMS, let message):
                return .halted(reason: .startFailed, atMS: atMS, detail: message)
            default:
                // 遅れて届いたbufferなどで録音中へ戻さない。interruptionEndedでも再開しない
                return phase
            }
        case .recording(let startedAtMS, _):
            switch event {
            case .bufferArrived(let atMS):
                return .recording(startedAtMS: startedAtMS, lastBufferAtMS: atMS)
            case .interruptionBegan(let atMS):
                return .halted(reason: .interrupted, atMS: atMS, detail: nil)
            case .configurationChanged(let atMS):
                return .halted(reason: .routeChanged, atMS: atMS, detail: nil)
            case .mediaServicesReset(let atMS):
                return .halted(reason: .mediaServicesReset, atMS: atMS, detail: nil)
            case .writeFailed(let atMS, let message):
                return .halted(reason: .writeFailed, atMS: atMS, detail: message)
            case .becameActive(let atMS):
                return isStale(phase, nowMS: atMS, queueDepth: queueDepth) ? .halted(reason: .noAudio, atMS: atMS, detail: nil) : phase
            default:
                return phase
            }
        }
    }

    public static func display(
        _ phase: WatchRecordingPhase, nowMS: Int64, queueDepth: Int = 0
    ) -> WatchRecordingDisplay {
        switch phase {
        case .idle:
            return WatchRecordingDisplay(isActive: false, message: IndicatorMessage(severity: .normal, text: ""))
        case .recording:
            if isStale(phase, nowMS: nowMS, queueDepth: queueDepth) {
                return WatchRecordingDisplay(
                    isActive: true,
                    message: IndicatorMessage(severity: .alert, text: "音声が届いていません")
                )
            }
            return WatchRecordingDisplay(isActive: true, message: IndicatorMessage(severity: .normal, text: "録音中"))
        case .halted(let reason, _, _):
            return WatchRecordingDisplay(
                isActive: false,
                message: IndicatorMessage(severity: .alert, text: "止まりました: \(reasonText(reason))")
            )
        }
    }

    private static func isStale(_ phase: WatchRecordingPhase, nowMS: Int64, queueDepth: Int) -> Bool {
        guard queueDepth <= 0 else { return false }
        guard case .recording(let startedAtMS, let lastBufferAtMS) = phase else { return false }
        return nowMS - (lastBufferAtMS ?? startedAtMS) > noAudioHaltMS
    }

    private static func reasonText(_ reason: WatchHaltReason) -> String {
        switch reason {
        case .startFailed: return "開始に失敗"
        case .interrupted: return "割り込み（通話・Siriなど）"
        case .routeChanged: return "音声の経路が変わった"
        case .mediaServicesReset: return "音声サービスの再起動"
        case .writeFailed: return "書き込みに失敗"
        case .noAudio: return "音声が途切れた"
        }
    }
}
