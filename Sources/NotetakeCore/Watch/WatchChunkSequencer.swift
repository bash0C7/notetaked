import Foundation

/// 小片をindex昇順で流す。次に流すべきindexより大きい小片は保留し、
/// 保留数が`maxPending`を超えたら飛ばして進める（飛んだ小片はあとから届いても捨てる）。
/// sessionはインスタンスごとに1つだけ扱う（最初に受け取ったsessionと異なるものは無視する）
public struct WatchChunkSequencer: Sendable {
    private let maxPending: Int
    private var session: String?
    private var pending: [Int: WatchChunkMetadata] = [:]
    public private(set) var nextIndex: Int = 0

    public init(maxPending: Int = 3) {
        self.maxPending = maxPending
    }

    /// いま流してよい小片をindex順で返す（受け入れたものを含む）
    public mutating func accept(_ meta: WatchChunkMetadata) -> [WatchChunkMetadata] {
        if let session {
            guard session == meta.session else { return [] }
        } else {
            session = meta.session
        }

        guard meta.index >= nextIndex else {
            return []
        }

        if meta.index == nextIndex {
            var out = [meta]
            nextIndex += 1
            out.append(contentsOf: drainConsecutivePending())
            return out
        }

        pending[meta.index] = meta
        guard pending.count > maxPending else {
            return []
        }

        guard let smallest = pending.keys.min() else {
            return []
        }
        nextIndex = smallest
        return drainConsecutivePending()
    }

    /// 保留を全部index順で出す（停止時）
    public mutating func flush() -> [WatchChunkMetadata] {
        let sortedKeys = pending.keys.sorted()
        let out = sortedKeys.map { pending.removeValue(forKey: $0)! }
        if let last = sortedKeys.last {
            nextIndex = last + 1
        }
        return out
    }

    private mutating func drainConsecutivePending() -> [WatchChunkMetadata] {
        var out: [WatchChunkMetadata] = []
        while let next = pending.removeValue(forKey: nextIndex) {
            out.append(next)
            nextIndex += 1
        }
        return out
    }
}
