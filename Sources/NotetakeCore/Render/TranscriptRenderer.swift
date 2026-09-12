import Foundation

/// 確定済みutterance列をMarkdown transcript（`<start>.final.md`）向けのテキストへ変換する純粋関数。
public enum TranscriptRenderer {
    /// 各utteranceを "HH:mm:ss **話者**: 本文\n" で連結。本文中の改行は空白に置換。空配列なら ""
    public static func markdown(_ utterances: [Utterance], timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"

        var result = ""
        for utterance in utterances {
            let time = formatter.string(from: Date(timeIntervalSince1970: Double(utterance.start) / 1000))
            let text = utterance.text.replacingOccurrences(of: "\n", with: " ")
            result += "\(time) **\(utterance.speaker)**: \(text)\n"
        }
        return result
    }
}
