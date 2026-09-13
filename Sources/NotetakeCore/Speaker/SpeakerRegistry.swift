import Foundation

/// Mac横断で永続化される話者プロファイル（大域id・命名・centroid）。
public struct SpeakerProfile: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var centroid: [Float]
    public var count: Int

    public init(id: String, name: String? = nil, centroid: [Float], count: Int) {
        self.id = id
        self.name = name
        self.centroid = centroid
        self.count = count
    }
}

/// stream（mic/system）内のlocal idを、cosine最近傍でMac横断の大域idへ束ねる純粋ロジック。
/// ネットワークやファイルI/Oには依存しない（読み書きはSessionStore / 呼び出し側が行う）。
public struct SpeakerRegistry: Sendable {
    public struct Config: Sendable {
        public var threshold: Float = 0.7
        public init() {}
    }

    private let config: Config
    public private(set) var profiles: [SpeakerProfile]
    /// "streamKey#localID" -> 大域id。同一stream内で一度決まった対応はchunk横断で固定する。
    private var streamAssignments: [String: String] = [:]

    public init(config: Config = Config(), profiles: [SpeakerProfile] = []) {
        self.config = config
        self.profiles = profiles
    }

    /// streamKey（mic/system等）内のlocalIDへ大域idを割り当てる。
    /// 既に対応が決まっていればそれを再利用し、centroidを更新する。
    /// 未対応ならcosine最近傍を探し、閾値以上ならそのidを、無ければ新規idを割り当てる。
    @discardableResult
    public mutating func assign(streamKey: String, localID: String, embedding: [Float]) -> String {
        let key = "\(streamKey)#\(localID)"

        if let existingID = streamAssignments[key] {
            updateCentroid(for: existingID, with: embedding)
            return existingID
        }

        if let match = bestMatch(for: embedding), match.similarity >= config.threshold {
            streamAssignments[key] = match.id
            updateCentroid(for: match.id, with: embedding)
            return match.id
        }

        let newID = nextID()
        profiles.append(
            SpeakerProfile(id: newID, name: nil, centroid: Self.normalize(embedding), count: 1))
        streamAssignments[key] = newID
        return newID
    }

    public mutating func setName(_ name: String, for id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    public func name(for id: String) -> String? {
        profiles.first(where: { $0.id == id })?.name
    }

    public var namedProfiles: [SpeakerProfile] {
        profiles.filter { $0.name != nil }
    }

    /// 長さ不一致・どちらかが零ベクトルなら0を返す。
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    private func bestMatch(for embedding: [Float]) -> (id: String, similarity: Float)? {
        var best: (id: String, similarity: Float)?
        for profile in profiles {
            let similarity = Self.cosineSimilarity(embedding, profile.centroid)
            if best == nil || similarity > best!.similarity {
                best = (profile.id, similarity)
            }
        }
        return best
    }

    /// centroid = normalize(centroid*count + normalize(embedding))、countは+1。
    private mutating func updateCentroid(for id: String, with embedding: [Float]) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let normalizedNew = Self.normalize(embedding)
        let oldCentroid = profiles[index].centroid
        let count = Float(profiles[index].count)

        var weighted = [Float](repeating: 0, count: oldCentroid.count)
        for i in 0..<oldCentroid.count {
            let newComponent = i < normalizedNew.count ? normalizedNew[i] : 0
            weighted[i] = oldCentroid[i] * count + newComponent
        }

        profiles[index].centroid = Self.normalize(weighted)
        profiles[index].count += 1
    }

    /// 既存の`g\d+`idの最大数値+1。既存が無ければ"g1"。
    private func nextID() -> String {
        let maxN =
            profiles
            .compactMap { profile -> Int? in
                guard profile.id.hasPrefix("g") else { return nil }
                return Int(profile.id.dropFirst())
            }
            .max() ?? 0
        return "g\(maxN + 1)"
    }

    private static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
