import Foundation

/// 状態表示の時刻。経過秒は長く放置すると桁が膨らむので、壁時計の日付時刻（秒まで）で出す
public enum StatusClockText {
    /// `yyyy-MM-dd HH:mm:ss`。`nil`は`—`
    public static func text(atMS: Int64?, timeZone: TimeZone = .current) -> String {
        guard let atMS else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(atMS) / 1000))
    }
}
