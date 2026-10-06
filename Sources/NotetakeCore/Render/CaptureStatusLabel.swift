/// メニューに出す、sourceごとの取り込みの状態の文
public enum CaptureStatusLabel {
    public static func text(for status: CaptureStatus) -> String {
        let name =
            switch status.source {
            case .mic: "マイク"
            case .system: "system音声"
            case .watch: "Watch"
            }
        switch status.state {
        case .recording:
            return "\(name): 取り込み中"
        case .retrying:
            return "\(name): 再開待ち" + (status.reason.map { "（\($0)）" } ?? "")
        case .off:
            return "\(name): 停止"
        }
    }
}
