import Foundation

public enum VoiceSimilarity {
    /// 声の特徴（centroid）同士のcosine類似度。次元が違う、空、零ベクトルは0
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            let x = Double(lhs[index])
            let y = Double(rhs[index])
            dot += x * y
            lhsNorm += x * x
            rhsNorm += y * y
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }
}

public struct SpeakerMatch: Equatable, Sendable {
    public var current: String
    public var previous: String
    public var similarity: Double

    public init(current: String, previous: String, similarity: Double) {
        self.current = current
        self.previous = previous
        self.similarity = similarity
    }
}

/// 確定し直した新しい話者と、前回の名前付きの話者を声の特徴で対応させる
public enum SpeakerMatcher {
    /// 同じ収録の別人同士が実測で最大0.62だったことから、それより上に余裕を取った値
    public static let threshold = 0.7

    /// 全ての組を類似度の高い順に並べる。同じ類似度は話者idの順
    public static func pairs(current: [String: [Float]], previous: [String: [Float]]) -> [SpeakerMatch] {
        var all: [SpeakerMatch] = []
        for (currentID, currentCentroid) in current {
            for (previousID, previousCentroid) in previous {
                all.append(
                    SpeakerMatch(
                        current: currentID, previous: previousID,
                        similarity: VoiceSimilarity.cosine(currentCentroid, previousCentroid)))
            }
        }
        return all.sorted {
            ($1.similarity, $0.current, $0.previous) < ($0.similarity, $1.current, $1.previous)
        }
    }

    /// `threshold`以上の組を類似度の高い順に1対1で対応させる
    public static func match(
        current: [String: [Float]], previous: [String: [Float]], threshold: Double = threshold
    ) -> [SpeakerMatch] {
        var usedCurrent: Set<String> = []
        var usedPrevious: Set<String> = []
        var matches: [SpeakerMatch] = []
        for pair in pairs(current: current, previous: previous) where pair.similarity >= threshold {
            guard !usedCurrent.contains(pair.current), !usedPrevious.contains(pair.previous) else { continue }
            usedCurrent.insert(pair.current)
            usedPrevious.insert(pair.previous)
            matches.append(pair)
        }
        return matches
    }

    /// 新しい話者ごとの、最も近い前回の話者。引き継げなかった話者の類似度を測るために使う
    public static func closest(current: [String: [Float]], previous: [String: [Float]]) -> [SpeakerMatch] {
        var best: [String: SpeakerMatch] = [:]
        for pair in pairs(current: current, previous: previous) where best[pair.current] == nil {
            best[pair.current] = pair
        }
        return best.values.sorted { $0.current < $1.current }
    }
}
