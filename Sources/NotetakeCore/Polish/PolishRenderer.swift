import Foundation

/// 整形済みturn列をMarkdown（`<start>.polished.md`）向けのテキストへ変換する純粋関数。
public enum PolishRenderer {
    /// 各turnを "HH:mm:ss **話者**: 本文\n"（startMSが無ければ時刻を省略）で連結。本文中の改行は空白に置換。
    /// polished == false のturnが1件以上あれば末尾に失敗件数の注記を付ける。空配列なら ""
    public static func markdown(_ turns: [PolishedTurn], timeZone: TimeZone) -> String {
        guard !turns.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"

        var result = ""
        var failureCount = 0
        for turn in turns {
            let text = String(turn.text.map { $0.isNewline ? " " : $0 })
            if let startMS = turn.startMS {
                let time = formatter.string(from: Date(timeIntervalSince1970: Double(startMS) / 1000))
                result += "\(time) **\(turn.speaker)**: \(text)\n"
            } else {
                result += "**\(turn.speaker)**: \(text)\n"
            }
            if !turn.polished {
                failureCount += 1
            }
        }
        if failureCount > 0 {
            result += "\n> 整形に失敗したturn: \(failureCount)件（原文のまま）\n"
        }
        return result
    }
}
