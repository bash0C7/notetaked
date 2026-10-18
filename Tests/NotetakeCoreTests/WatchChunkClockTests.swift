import Foundation
import Testing
@testable import NotetakeCore

@Test func firstBufferAnchorsTheChunkStart() {
    var clock = WatchChunkClock(sampleRate: 48_000)
    #expect(clock.chunkStartMS == nil)
    let first = clock.bufferArrived(wallMS: 5_000, frames: 4_800)
    #expect(first)
    #expect(clock.chunkStartMS == 5_000)
}

@Test func laterBuffersOnlyAddFrames() {
    var clock = WatchChunkClock(sampleRate: 48_000)
    let first = clock.bufferArrived(wallMS: 1_000, frames: 4_800)
    #expect(first)
    for i in 1..<10 {
        let again = clock.bufferArrived(wallMS: 1_000 + Int64(i) * 100, frames: 4_800)
        #expect(again == false)
    }
    #expect(clock.chunkStartMS == 1_000)
    #expect(clock.chunkDurationMS == 1_000)
}

@Test func closeReturnsStartAndDurationAndResets() {
    var clock = WatchChunkClock(sampleRate: 48_000)
    _ = clock.bufferArrived(wallMS: 7_000, frames: 96_000)
    let closed = clock.closeChunk()
    #expect(closed?.startMS == 7_000)
    #expect(closed?.durationMS == 2_000)
    #expect(clock.chunkStartMS == nil)
    #expect(clock.chunkDurationMS == 0)
}

@Test func closeWithNothingWrittenIsNil() {
    var clock = WatchChunkClock(sampleRate: 48_000)
    #expect(clock.closeChunk() == nil)
}

@Test func aGapBetweenChunksIsNotSqueezed() {
    var clock = WatchChunkClock(sampleRate: 48_000)
    _ = clock.bufferArrived(wallMS: 0, frames: 48_000 * 20)
    let first = clock.closeChunk()
    #expect(first?.startMS == 0)
    #expect(first?.durationMS == 20_000)
    let anchored = clock.bufferArrived(wallMS: 25_000, frames: 4_800)
    #expect(anchored)
    let second = clock.closeChunk()
    #expect(second?.startMS == 25_000)
}

@Test func wallMSMapsHostTimeBackFromNow() {
    // 1 tick = 1 ns。2秒前のbuffer
    let wall = WatchChunkClock.wallMS(
        hostTime: 8_000_000_000, nowHostTime: 10_000_000_000, nowWallMS: 100_000, ticksToNanos: { $0 })
    #expect(wall == 98_000)
}

@Test func futureHostTimeClampsToNow() {
    let wall = WatchChunkClock.wallMS(
        hostTime: 11_000_000_000, nowHostTime: 10_000_000_000, nowWallMS: 100_000, ticksToNanos: { $0 })
    #expect(wall == 100_000)
    let unknown = WatchChunkClock.wallMS(
        hostTime: 0, nowHostTime: 10_000_000_000, nowWallMS: 100_000, ticksToNanos: { $0 })
    #expect(unknown == 100_000)
}

@Test func gateWritesUnderTheHighWatermark() {
    var gate = WatchOverflowGate()
    #expect(gate.decide(depth: 0) == .write)
    #expect(gate.decide(depth: 240) == .write)
}

@Test func gateStartsDroppingAboveTheHighWatermark() {
    var gate = WatchOverflowGate()
    #expect(gate.decide(depth: 241) == .dropStartingOverflow(depth: 241))
}

@Test func gateKeepsDroppingUntilTheLowWatermark() {
    var gate = WatchOverflowGate()
    #expect(gate.decide(depth: 241) == .dropStartingOverflow(depth: 241))
    #expect(gate.decide(depth: 200) == .drop)
    #expect(gate.decide(depth: 100) == .drop)
    #expect(gate.decide(depth: 25) == .drop)
    #expect(gate.decide(depth: 24) == .resume(droppedBuffers: 4, maxDepth: 241))
    #expect(gate.decide(depth: 24) == .write)
}

@Test func gateDoesNotFlapAroundTheHighWatermark() {
    var gate = WatchOverflowGate()
    var starts = 0
    for i in 0..<20 {
        let depth = i % 2 == 0 ? 241 : 240
        if case .dropStartingOverflow = gate.decide(depth: depth) { starts += 1 }
    }
    #expect(starts == 1)
}

@Test func rotationWaitsForTheNextBufferAfterTheLimit() {
    #expect(WatchChunkRotation.shouldCloseBeforeWriting(framesInChunk: 959_999, limit: 960_000, overflowPending: false) == false)
    // 上限ちょうどで停止しても、今の小片は1 frame以上を持ったまま閉じられる（次のbufferが来るまで閉じない）
    #expect(WatchChunkRotation.shouldCloseBeforeWriting(framesInChunk: 960_000, limit: 960_000, overflowPending: false))
}

@Test func overflowClosesOnlyAChunkThatHasFrames() {
    #expect(WatchChunkRotation.shouldCloseBeforeWriting(framesInChunk: 4_096, limit: 960_000, overflowPending: true))
    // 容量溢れの最中に停止しても空の小片を作らない
    #expect(WatchChunkRotation.shouldCloseBeforeWriting(framesInChunk: 0, limit: 960_000, overflowPending: true) == false)
}
