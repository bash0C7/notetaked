import Foundation

/// 表示の深刻度。cautionが黄、alertが赤、infoは色を付けない情報
public enum IndicatorSeverity: Sendable, Equatable {
    case normal, info, caution, alert
}

public struct IndicatorMessage: Sendable, Equatable {
    public var severity: IndicatorSeverity
    public var text: String

    public init(severity: IndicatorSeverity, text: String) {
        self.severity = severity
        self.text = text
    }
}

/// 1つのsourceの判定に要る入力。時刻はすべてms
public struct SourceIndicatorInput: Sendable, Equatable {
    public var history: LevelHistory
    public var captureState: CaptureSourceState?
    public var captureReason: String?
    public var recording: Bool
    public var recordingStartedAtMS: Int64?
    public var lastTextAtMS: Int64?
    public var nowMS: Int64

    public init(
        history: LevelHistory,
        captureState: CaptureSourceState?,
        captureReason: String?,
        recording: Bool,
        recordingStartedAtMS: Int64?,
        lastTextAtMS: Int64?,
        nowMS: Int64
    ) {
        self.history = history
        self.captureState = captureState
        self.captureReason = captureReason
        self.recording = recording
        self.recordingStartedAtMS = recordingStartedAtMS
        self.lastTextAtMS = lastTextAtMS
        self.nowMS = nowMS
    }
}

/// 赤・黄・正常の判定。状態を持たない純粋関数
public enum IndicatorJudge {
    public static let silenceAlertMS: Int64 = 3_000
    public static let startupGraceMS: Int64 = 5_000
    public static let noTextCautionMS: Int64 = 30_000
    public static let soundThresholdDBFS: Double = -50
    public static let daemonAlertMS: Int64 = 15_000

    public static func judge(_ input: SourceIndicatorInput) -> IndicatorMessage {
        let now = input.nowMS

        if input.captureState == .retrying {
            let text = input.captureReason.map { "取り込み再接続中: \($0)" } ?? "取り込み再接続中"
            return IndicatorMessage(severity: .alert, text: text)
        }

        if input.history.trailingSilenceMS(nowMS: now) >= silenceAlertMS {
            return IndicatorMessage(severity: .alert, text: "音声がゼロです（入力が無音）")
        }

        if input.recording, input.history.latest?.dbfs == nil {
            let startedAt = input.recordingStartedAtMS ?? now
            if now - startedAt > startupGraceMS {
                return IndicatorMessage(severity: .alert, text: "音声が届いていません")
            }
            return IndicatorMessage(severity: .info, text: "取得待ち")
        }

        if input.recording {
            let noRecentText = input.lastTextAtMS.map { now - $0 >= noTextCautionMS } ?? true
            if noRecentText,
               input.history.hasSound(above: soundThresholdDBFS, sinceMS: now - noTextCautionMS) {
                return IndicatorMessage(severity: .caution, text: "音はあるのに文字が出ていません")
            }
        }

        return IndicatorMessage(severity: .normal, text: "")
    }

    /// daemonの更新が途絶えたら赤。まだ一度も更新が無い（nil）場合も赤
    public static func judgeDaemon(lastUpdatedMS: Int64?, nowMS: Int64) -> IndicatorMessage? {
        guard let lastUpdatedMS, nowMS - lastUpdatedMS < daemonAlertMS else {
            return IndicatorMessage(severity: .alert, text: "取り込みdaemonからの更新が止まっています")
        }
        return nil
    }

    public static func judgePeer(wasConnected: Bool, connected: Bool) -> IndicatorMessage? {
        guard wasConnected, !connected else { return nil }
        return IndicatorMessage(severity: .caution, text: "iPhoneとの接続が切れました")
    }

    /// 蓋が閉じていて内蔵マイクが使えないのは想定どおりなので、赤にせず情報として出す
    public static func lidClosedMessage(clamshellClosed: Bool, micUnavailable: Bool) -> IndicatorMessage? {
        guard clamshellClosed, micUnavailable else { return nil }
        return IndicatorMessage(severity: .info, text: "蓋が閉じているため内蔵マイクは使えません")
    }
}
