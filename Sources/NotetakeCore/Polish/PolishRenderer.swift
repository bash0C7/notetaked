import Foundation

/// 整形済みturn列を対話だけのMarkdown（`<start>.polished.md`）へ変換する純粋関数。時刻は出さない
public enum PolishRenderer {
    /// 先頭 "# yyyy-MM-dd 参加者、参加者" + 空行、以降 "**話者**: 本文" を1行ずつ。本文中の改行は空白に置換。
    /// polished == false のturnが1件以上あれば末尾に失敗件数の注記。空配列なら ""
    public static func markdown(_ turns: [PolishedTurn], recordedAt: Date, timeZone: TimeZone) -> String {
        guard !turns.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var result = "# \(formatter.string(from: recordedAt)) \(participants(turns).joined(separator: "、"))\n\n"
        var failureCount = 0
        for turn in turns {
            let text = String(turn.text.map { $0.isNewline ? " " : $0 })
            result += "**\(turn.speaker)**: \(text)\n"
            if !turn.polished { failureCount += 1 }
        }
        if failureCount > 0 {
            result += "\n> 整形に失敗したturn: \(failureCount)件（原文のまま）\n"
        }
        return result
    }

    /// 登場順・重複なしの話者ラベル
    public static func participants(_ turns: [PolishedTurn]) -> [String] {
        var seen = Set<String>()
        return turns.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }
}
