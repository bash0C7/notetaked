import Foundation

/// Watchの状態の判定。iPhoneとMacで共有する。状態を持たない純粋関数
public enum WatchStatusJudge {
    public static let staleCautionMS: Int64 = 180_000
    public static let lowBatteryLevel: Double = 0.2

    public static func judge(_ snapshot: WatchStatusSnapshot?, nowMS: Int64) -> IndicatorMessage {
        guard let snapshot else { return empty }

        if snapshot.state == .halted {
            let text = snapshot.haltReason.map { "Watchが止まりました: \($0.displayText)" } ?? "Watchが止まりました"
            return IndicatorMessage(severity: .alert, text: text)
        }

        let recording = snapshot.state == .recording

        // 小片がまだ届いていない間は、録音の開始から数える
        let lastReceived = snapshot.lastChunkReceivedAtMS ?? snapshot.stateAtMS ?? snapshot.updatedAtMS
        if recording, nowMS - lastReceived >= staleCautionMS {
            let minutes = (nowMS - lastReceived) / 60_000
            return IndicatorMessage(severity: .caution, text: "Watchから届いていません（\(minutes)分）")
        }

        if snapshot.inboxPendingCount > 0 {
            return IndicatorMessage(
                severity: .info, text: "未処理\(snapshot.inboxPendingCount)件（iPhoneを開くと文字起こし）")
        }

        if recording, let level = snapshot.batteryLevel, level < lowBatteryLevel {
            return IndicatorMessage(severity: .caution, text: "Watchの電池が少ない（\(Int((level * 100).rounded()))%）")
        }

        if recording { return IndicatorMessage(severity: .normal, text: "Watch録音中") }
        return empty
    }

    private static var empty: IndicatorMessage { IndicatorMessage(severity: .normal, text: "") }
}
