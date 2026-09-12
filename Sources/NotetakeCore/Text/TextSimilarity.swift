import Foundation

public enum TextSimilarity {
    /// NFKC正規化（precomposedStringWithCompatibilityMapping）後、isWhitespace / isPunctuation / isSymbolのCharacterを除去
    public static func normalized(_ s: String) -> String {
        let folded = s.precomposedStringWithCompatibilityMapping
        return String(folded.filter { !($0.isWhitespace || $0.isPunctuation || $0.isSymbol) })
    }

    /// normalized後の文字bigram多重集合のDice係数（0...1）。両方が1文字以下なら normalized が等しければ1、違えば0
    public static func bigramDice(_ a: String, _ b: String) -> Double {
        let na = normalized(a)
        let nb = normalized(b)

        if na.count <= 1 && nb.count <= 1 {
            return na == nb ? 1.0 : 0.0
        }

        let bigramsA = bigramCounts(of: na)
        let bigramsB = bigramCounts(of: nb)
        let totalA = bigramsA.values.reduce(0, +)
        let totalB = bigramsB.values.reduce(0, +)

        var intersection = 0
        for (bigram, countA) in bigramsA {
            if let countB = bigramsB[bigram] {
                intersection += min(countA, countB)
            }
        }

        return (2.0 * Double(intersection)) / Double(totalA + totalB)
    }

    private static func bigramCounts(of s: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let chars = Array(s)
        guard chars.count >= 2 else { return counts }
        for i in 0..<(chars.count - 1) {
            let bigram = String(chars[i...(i + 1)])
            counts[bigram, default: 0] += 1
        }
        return counts
    }
}
