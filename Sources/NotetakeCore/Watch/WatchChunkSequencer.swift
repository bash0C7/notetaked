import Foundation

/// 小片をindex昇順で流す。次に流すべきindexより大きい小片は保留する。
/// 保留は、`maxPendingAgeMS == nil`なら件数が`maxPending`を超えた時、渡すと最古の保留がその時間待った時に
/// 飛ばして進める（飛んだ小片はあとから届くと`accept`は捨てる。拾い直すのは呼び出し側）。
/// sessionはインスタンスごとに1つだけ扱う（最初に受け取ったsessionと異なるものは無視する）
public struct WatchChunkSequencer: Sendable {
    private struct Held: Sendable {
        var meta: WatchChunkMetadata
        var atMS: Int64
    }

    private let maxPending: Int
    private let maxPendingAgeMS: Int64?
    private var session: String?
    private var pending: [Int: Held] = [:]
    public private(set) var nextIndex: Int

    /// `startingAt`は台帳から続きを始める時
    public init(maxPending: Int = 3, maxPendingAgeMS: Int64? = nil, startingAt nextIndex: Int = 0) {
        self.maxPending = maxPending
        self.maxPendingAgeMS = maxPendingAgeMS
        self.nextIndex = nextIndex
    }

    /// いま流してよい小片をindex順で返す（受け入れたものを含む）
    public mutating func accept(_ meta: WatchChunkMetadata) -> [WatchChunkMetadata] {
        accept(meta, atMS: 0).ready
    }

    /// `atMS`はその小片の受信時刻。保留に入れた時刻として、待った時間の起点になる。
    /// 飛ばしたindexも返す
    public mutating func accept(
        _ meta: WatchChunkMetadata, atMS: Int64
    ) -> (ready: [WatchChunkMetadata], skipped: [Int]) {
        if let session {
            guard session == meta.session else { return ([], []) }
        } else {
            session = meta.session
        }
        guard meta.index >= nextIndex else { return ([], []) }

        var ready: [WatchChunkMetadata] = []
        var skipped: [Int] = []
        if meta.index == nextIndex {
            ready.append(meta)
            nextIndex += 1
            ready.append(contentsOf: drainConsecutivePending())
        } else {
            pending[meta.index] = Held(meta: meta, atMS: atMS)
            if maxPendingAgeMS == nil, pending.count > maxPending {
                skipToSmallestPending(ready: &ready, skipped: &skipped)
            }
        }
        releaseAged(nowMS: atMS, ready: &ready, skipped: &skipped)
        return (ready, skipped)
    }

    /// 新しい小片が来なくても、古い保留を流す
    public mutating func tick(atMS: Int64) -> (ready: [WatchChunkMetadata], skipped: [Int]) {
        var ready: [WatchChunkMetadata] = []
        var skipped: [Int] = []
        releaseAged(nowMS: atMS, ready: &ready, skipped: &skipped)
        return (ready, skipped)
    }

    /// 保留を全部index順で出す（停止時）
    public mutating func flush() -> [WatchChunkMetadata] {
        let sortedKeys = pending.keys.sorted()
        let out = sortedKeys.map { pending.removeValue(forKey: $0)!.meta }
        if let last = sortedKeys.last {
            nextIndex = last + 1
        }
        return out
    }

    private mutating func releaseAged(
        nowMS: Int64, ready: inout [WatchChunkMetadata], skipped: inout [Int]
    ) {
        guard let maxPendingAgeMS else { return }
        while let oldest = pending.values.map(\.atMS).min(), nowMS - oldest >= maxPendingAgeMS {
            skipToSmallestPending(ready: &ready, skipped: &skipped)
        }
    }

    private mutating func skipToSmallestPending(ready: inout [WatchChunkMetadata], skipped: inout [Int]) {
        guard let smallest = pending.keys.min() else { return }
        skipped.append(contentsOf: nextIndex..<smallest)
        nextIndex = smallest
        ready.append(contentsOf: drainConsecutivePending())
    }

    private mutating func drainConsecutivePending() -> [WatchChunkMetadata] {
        var out: [WatchChunkMetadata] = []
        while let next = pending.removeValue(forKey: nextIndex) {
            out.append(next.meta)
            nextIndex += 1
        }
        return out
    }
}
