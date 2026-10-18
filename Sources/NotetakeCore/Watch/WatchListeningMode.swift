import Foundation

/// Watch受信モード。iPhoneが無音を再生し続けて背面で生き、Watchの小片を随時受け取る。
/// Watchが手首を下げると`isReachable`が落ち、合図で起こせないことへの代替
public struct WatchListeningMode: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var enabledAtMS: Int64?

    /// 12時間。1日1回、前面で入れる運用。切り忘れで電池を使い続けない
    public static let autoOffMS: Int64 = 43_200_000

    public enum Decision: Sendable, Equatable {
        case play, stop, stopAndDisable
    }

    public init(enabled: Bool = false, enabledAtMS: Int64? = nil) {
        self.enabled = enabled
        self.enabledAtMS = enabledAtMS
    }

    public mutating func enable(atMS: Int64) {
        enabled = true
        enabledAtMS = atMS
    }

    public mutating func disable() {
        enabled = false
        enabledAtMS = nil
    }

    /// 入切・mic収録の開始と停止・中断の終わり・前面化のたびに呼ぶ。
    /// iPhoneのmic収録中は止める（`Recorder`のaudio sessionが背面を保つので、categoryを奪い合わない）
    public func decide(nowMS: Int64, isMicRecording: Bool) -> Decision {
        guard enabled else { return .stop }
        // 入れた時刻が無い（壊れた保存）時は、期限を測れないので切る。期限無効のまま電池を使い続けない
        guard let enabledAtMS else { return .stopAndDisable }
        if nowMS - enabledAtMS >= Self.autoOffMS { return .stopAndDisable }
        if isMicRecording { return .stop }
        return .play
    }

    /// 自動offまでの残り（ms）。入っていなければ`nil`、入れた時刻が無ければ0（すぐ切る）。
    /// 無音再生で背面に生き続けるので、この時間だけ待つタスクで期限を見張る
    public func remainingUntilAutoOffMS(nowMS: Int64) -> Int64? {
        guard enabled else { return nil }
        guard let enabledAtMS else { return 0 }
        return max(0, enabledAtMS + Self.autoOffMS - nowMS)
    }
}
