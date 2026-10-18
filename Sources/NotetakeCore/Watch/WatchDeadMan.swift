import Foundation

public enum WatchDeadManAction: Sendable, Equatable {
    case schedule(fireAtMS: Int64)
    case cancel
    case none
}

/// 録音が止まったのにWatchの画面を見ていない時に、ローカル通知で知らせるための予約の延長と取り消し。
/// 録音中は小片を閉じるたびに予約を先へ延ばす。appが止まると延びずにそのまま鳴る
public enum WatchDeadMan {
    public static let graceMS: Int64 = 180_000

    /// `previous`・`next`は`dispatch`の前後のphase。eventの無い呼び出し（小片を閉じた時）は`previous == next`を渡す
    public static func action(
        for event: WatchRecordingEvent?,
        chunkClosedAtMS: Int64?,
        previous: WatchRecordingPhase,
        next: WatchRecordingPhase
    ) -> WatchDeadManAction {
        if case .stopped = event { return .cancel }
        if case .recording = previous, case .halted = next { return .cancel }
        if case .recording(let startedAtMS, _) = next {
            if case .recording = previous {
                guard let chunkClosedAtMS else { return .none }
                return .schedule(fireAtMS: chunkClosedAtMS + graceMS)
            }
            return .schedule(fireAtMS: startedAtMS + graceMS)
        }
        return .none
    }
}
