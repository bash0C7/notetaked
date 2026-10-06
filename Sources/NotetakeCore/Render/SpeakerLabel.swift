import Foundation

public enum SpeakerLabel {
    /// 名前の無い確定版の話者（`s1`、`s2`…）は「話者1」「話者2」…と表示する。それ以外のidはそのまま使う
    public static func defaultName(for id: String) -> String {
        let digits = id.dropFirst()
        guard id.first == "s", !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }),
            let number = Int(digits)
        else {
            return id
        }
        return "話者\(number)"
    }
}
