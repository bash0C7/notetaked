import Foundation

/// 録音したい状態。開始で`wantsRecording`を立て、停止・自動停止で下ろす。
/// 起動した時に立ったまま録音していなければ、前回の録音は中断されたと分かる
public struct WatchRecordingIntent: Codable, Sendable, Equatable {
    public var wantsRecording: Bool
    public var session: String?
    public var startedAtMS: Int64?

    /// 10時間
    public static let autoStopMS: Int64 = 36_000_000

    public init(wantsRecording: Bool, session: String?, startedAtMS: Int64?) {
        self.wantsRecording = wantsRecording
        self.session = session
        self.startedAtMS = startedAtMS
    }

    public func interruptedOnLaunch(isRecording: Bool) -> Bool {
        wantsRecording && !isRecording
    }

    public func shouldAutoStop(nowMS: Int64) -> Bool {
        guard let startedAtMS else { return false }
        return nowMS - startedAtMS >= Self.autoStopMS
    }
}
