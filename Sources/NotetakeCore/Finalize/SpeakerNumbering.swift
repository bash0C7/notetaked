import Foundation

/// sourceの中で話者分離が付けた話者。`id`は`S1`のような、sourceごとに振られるid
public struct LocalSpeaker: Hashable, Sendable {
    public var source: Source
    public var id: String

    public init(source: Source, id: String) {
        self.source = source
        self.id = id
    }

    /// 確定版の発話の`speaker.local`に入れる文字列（`mic:S1`）
    public var tag: String { "\(source.rawValue):\(id)" }
}

public enum SpeakerNumbering {
    /// 確定処理の話者に、その回の中で最初に話した順に`s1`、`s2`…を振る。micとsystemの話者は別の話者として数える。
    /// 同じ時刻に話し始めた話者は、source名、話者idの順に並べる
    public static func assign(firstSpoken: [LocalSpeaker: Int64]) -> [LocalSpeaker: String] {
        let ordered = firstSpoken.sorted { lhs, rhs in
            (lhs.value, lhs.key.source.rawValue, lhs.key.id) < (rhs.value, rhs.key.source.rawValue, rhs.key.id)
        }
        var ids: [LocalSpeaker: String] = [:]
        for (offset, entry) in ordered.enumerated() {
            ids[entry.key] = "s\(offset + 1)"
        }
        return ids
    }
}
