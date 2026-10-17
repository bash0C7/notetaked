import Foundation

/// 小片1つの間に集める音量・電池・待ち行列の要約。小片を閉じる時に`applied(to:)`で`WatchChunkMetadata`へ写し、`reset()`で次の小片へ進む
public struct ChunkTelemetry: Sendable, Equatable {
    private var level = ChunkLevelSummary()
    private var batteryLevel: Double?
    private var maxQueueDepth: Int?

    public init() {}

    /// 電池は最後に分かった値を残す（`nil`では上書きしない）。待ち行列は小片内の最大
    public mutating func add(dbfs: Double, batteryLevel: Double?, queueDepth: Int) {
        level.add(dbfs: dbfs)
        if let batteryLevel { self.batteryLevel = batteryLevel }
        maxQueueDepth = max(maxQueueDepth ?? queueDepth, queueDepth)
    }

    public func applied(to metadata: WatchChunkMetadata) -> WatchChunkMetadata {
        var metadata = metadata
        metadata.maxDBFS = level.maxDBFS
        metadata.meanDBFS = level.meanDBFS
        metadata.batteryLevel = batteryLevel
        metadata.maxQueueDepth = maxQueueDepth
        return metadata
    }

    public mutating func reset() {
        self = ChunkTelemetry()
    }
}
