import Foundation

/// 小片1つの間に測ったdBFSの最大と算術平均。小片を閉じる時に`WatchChunkMetadata`へ写し、`reset()`で次の小片へ進む
public struct ChunkLevelSummary: Sendable, Equatable {
    private var count: Int = 0
    private var sum: Double = 0
    private var maxValue: Double?

    private static let floor: Double = -120

    public init() {}

    /// 非有限値と範囲外は-120...0に丸めてから集計する（NaNは無音の-120扱い）
    public mutating func add(dbfs: Double) {
        let dbfs: Double = dbfs.isNaN ? Self.floor : min(max(dbfs, Self.floor), 0)
        count += 1
        sum += dbfs
        maxValue = max(maxValue ?? dbfs, dbfs)
    }

    public var maxDBFS: Double? { maxValue }

    public var meanDBFS: Double? {
        count > 0 ? sum / Double(count) : nil
    }

    public mutating func reset() {
        self = ChunkLevelSummary()
    }
}
