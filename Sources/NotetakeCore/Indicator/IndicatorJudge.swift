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
    /// 蓋が閉じていて、収録するmicが内蔵。この時の無音・欠測は想定どおりなので赤にしない
    public var lidClosedBuiltInMic: Bool
    /// ちょうど-120 dBFSの無音を異常とみなす。何も再生していないsystem音声は常にこの値になるため、systemはfalse
    public var zeroSilenceIsAnomaly: Bool

    public init(
        history: LevelHistory,
        captureState: CaptureSourceState?,
        captureReason: String?,
        recording: Bool,
        recordingStartedAtMS: Int64?,
        lastTextAtMS: Int64?,
        nowMS: Int64,
        lidClosedBuiltInMic: Bool = false,
        zeroSilenceIsAnomaly: Bool = true
    ) {
        self.history = history
        self.captureState = captureState
        self.captureReason = captureReason
        self.recording = recording
        self.recordingStartedAtMS = recordingStartedAtMS
        self.lastTextAtMS = lastTextAtMS
        self.nowMS = nowMS
        self.lidClosedBuiltInMic = lidClosedBuiltInMic
        self.zeroSilenceIsAnomaly = zeroSilenceIsAnomaly
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
        let message = judgeIgnoringLid(input)
        if input.lidClosedBuiltInMic, message.severity == .alert,
           let lid = lidClosedMessage(clamshellClosed: true, micUnavailable: true) {
            return lid
        }
        return message
    }

    private static func judgeIgnoringLid(_ input: SourceIndicatorInput) -> IndicatorMessage {
        let now = input.nowMS

        if input.captureState == .retrying {
            let text = input.captureReason.map { "取り込み再接続中: \($0)" } ?? "取り込み再接続中"
            return IndicatorMessage(severity: .alert, text: text)
        }

        // 最新のsampleが古ければ、測れていない（欠測）として扱う
        let fresh = input.history.latest(nowMS: now)

        if input.zeroSilenceIsAnomaly, fresh?.dbfs != nil, input.history.trailingSilenceMS(nowMS: now) >= silenceAlertMS {
            return IndicatorMessage(severity: .alert, text: "音声がゼロです（入力が無音）")
        }

        if input.recording, fresh?.dbfs == nil {
            let startedAt = input.recordingStartedAtMS ?? now
            let gapLongEnough = input.history.lastMeasuredAtMS.map { now - $0 >= silenceAlertMS } ?? true
            if now - startedAt > startupGraceMS, gapLongEnough {
                return IndicatorMessage(severity: .alert, text: "音声が届いていません")
            }
            return IndicatorMessage(severity: .info, text: "取得待ち")
        }

        if input.recording {
            // 文字がまだ無い間は、収録の開始から30秒を数える
            let since = input.lastTextAtMS ?? input.recordingStartedAtMS ?? now
            if now - since >= noTextCautionMS,
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

    /// peerNameは切れた相手の呼び名。Macから見れば「iPhone」、iPhoneから見れば「Mac」
    public static func judgePeer(wasConnected: Bool, connected: Bool, peerName: String = "iPhone") -> IndicatorMessage? {
        guard wasConnected, !connected else { return nil }
        return IndicatorMessage(severity: .caution, text: "\(peerName)との接続が切れました")
    }

    /// 蓋が閉じていて内蔵マイクが使えないのは想定どおりなので、赤にせず情報として出す
    public static func lidClosedMessage(clamshellClosed: Bool, micUnavailable: Bool) -> IndicatorMessage? {
        guard clamshellClosed, micUnavailable else { return nil }
        return IndicatorMessage(severity: .info, text: "蓋が閉じているため内蔵マイクは使えません")
    }
}
