import Foundation

/// 小片の時刻。開始は最初のbufferの壁時計で決め、長さは書いたframe数から決める。
/// 小片と小片の間に途切れがあっても、frame数から計算した時刻に詰めない
public struct WatchChunkClock: Sendable, Equatable {
    private let sampleRate: Double
    private var startMS: Int64?
    private var frames: Int64 = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// 今の小片の最初のbufferならその`wallMS`を小片の開始として覚えて`true`。以後は書いたframe数を足すだけで`false`
    public mutating func bufferArrived(wallMS: Int64, frames: Int) -> Bool {
        let isFirst = startMS == nil
        if isFirst { startMS = wallMS }
        self.frames += Int64(frames)
        return isFirst
    }

    public var chunkStartMS: Int64? { startMS }

    public var chunkDurationMS: Int64 {
        Int64((Double(frames) / sampleRate * 1000).rounded())
    }

    /// 何も書いていなければ`nil`。閉じたら次の小片のために開始を空にする
    public mutating func closeChunk() -> (startMS: Int64, durationMS: Int64)? {
        guard let startMS, frames > 0 else {
            self.startMS = nil
            frames = 0
            return nil
        }
        let closed = (startMS: startMS, durationMS: chunkDurationMS)
        self.startMS = nil
        frames = 0
        return closed
    }

    /// bufferのhostTimeを壁時計へ写す。hostTimeが未来か不明（0）なら`nowWallMS`
    public static func wallMS(
        hostTime: UInt64, nowHostTime: UInt64, nowWallMS: Int64, ticksToNanos: (UInt64) -> UInt64
    ) -> Int64 {
        guard hostTime > 0, hostTime < nowHostTime else { return nowWallMS }
        let elapsedNanos = ticksToNanos(nowHostTime - hostTime)
        return nowWallMS - Int64((elapsedNanos + 500_000) / 1_000_000)
    }
}

/// 待ち行列の溢れの判定。上限と下限の間で行き来しないよう、捨て始めたら下限まで捨て続ける
public struct WatchOverflowGate: Sendable, Equatable {
    /// 4096 frame・48kHzで約20秒
    public static let highWatermark = 240
    public static let lowWatermark = 24

    public enum Decision: Sendable, Equatable {
        case write
        case dropStartingOverflow(depth: Int)
        case drop
        case resume(droppedBuffers: Int, maxDepth: Int)
    }

    private var dropping = false
    private var droppedBuffers = 0
    private var maxDepth = 0

    public init() {}

    public mutating func decide(depth: Int) -> Decision {
        if !dropping {
            guard depth > Self.highWatermark else { return .write }
            dropping = true
            droppedBuffers = 1
            maxDepth = depth
            return .dropStartingOverflow(depth: depth)
        }
        if depth > Self.lowWatermark {
            droppedBuffers += 1
            maxDepth = max(maxDepth, depth)
            return .drop
        }
        let resumed = Decision.resume(droppedBuffers: droppedBuffers, maxDepth: maxDepth)
        dropping = false
        droppedBuffers = 0
        maxDepth = 0
        return resumed
    }
}

/// 小片を閉じる時機。上限に達しても閉じず、次のbufferを書く直前に閉じる。
/// そうすれば停止の時に閉じる小片は必ず1 frame以上を持ち、`isFinal`を付けられる
public enum WatchChunkRotation {
    public static func shouldCloseBeforeWriting(framesInChunk: Int64, limit: Int64, overflowPending: Bool) -> Bool {
        guard framesInChunk > 0 else { return false }
        return framesInChunk >= limit || overflowPending
    }
}
