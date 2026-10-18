import Foundation
import Testing
@testable import NotetakeCore

private func fixtureMeta(
    session: String = "1700000000000",
    index: Int = 0,
    startAtMS: Int64 = 1_700_000_000_000,
    sampleRate: Double = 16000,
    device: String = "watch-abc",
    deviceName: String = "小芝のApple Watch",
    owner: String = "小芝"
) -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: session,
        index: index,
        startAtMS: startAtMS,
        sampleRate: sampleRate,
        device: device,
        deviceName: deviceName,
        owner: owner
    )
}

// MARK: - WatchChunkSequencer

@Test func sequencerEmitsInOrderChunksImmediately() {
    var sequencer = WatchChunkSequencer()
    let m0 = fixtureMeta(index: 0)
    let m1 = fixtureMeta(index: 1)
    let m2 = fixtureMeta(index: 2)

    #expect(sequencer.accept(m0) == [m0])
    #expect(sequencer.accept(m1) == [m1])
    #expect(sequencer.accept(m2) == [m2])
    #expect(sequencer.nextIndex == 3)
}

@Test func sequencerBuffersOutOfOrderChunksThenReleasesInOrder() {
    var sequencer = WatchChunkSequencer()
    let m0 = fixtureMeta(index: 0)
    let m1 = fixtureMeta(index: 1)
    let m2 = fixtureMeta(index: 2)

    #expect(sequencer.accept(m2) == [])
    #expect(sequencer.accept(m1) == [])
    #expect(sequencer.accept(m0) == [m0, m1, m2])
    #expect(sequencer.nextIndex == 3)
}

@Test func sequencerDropsDuplicateOrOldChunks() {
    var sequencer = WatchChunkSequencer()
    let m0 = fixtureMeta(index: 0)
    let m1 = fixtureMeta(index: 1)

    #expect(sequencer.accept(m0) == [m0])
    #expect(sequencer.accept(m1) == [m1])
    // duplicate of an already-emitted chunk
    #expect(sequencer.accept(m1) == [])
    // older than nextIndex
    #expect(sequencer.accept(m0) == [])
    #expect(sequencer.nextIndex == 2)
}

@Test func sequencerSkipsAheadAfterExceedingMaxPendingAndDropsLateSkippedChunk() {
    var sequencer = WatchChunkSequencer(maxPending: 3)
    let m1 = fixtureMeta(index: 1)
    let m2 = fixtureMeta(index: 2)
    let m3 = fixtureMeta(index: 3)
    let m6 = fixtureMeta(index: 6)
    let m7 = fixtureMeta(index: 7)
    let m8 = fixtureMeta(index: 8)
    let m9 = fixtureMeta(index: 9)
    let m4 = fixtureMeta(index: 4)

    #expect(sequencer.accept(m1) == [])
    #expect(sequencer.accept(m2) == [])
    #expect(sequencer.accept(m3) == [])
    // pending {1,2,3,6} exceeds maxPending(3) -> skip ahead to smallest pending (1),
    // draining consecutively until the real gap at 4
    #expect(sequencer.accept(m6) == [m1, m2, m3])
    #expect(sequencer.nextIndex == 4)

    #expect(sequencer.accept(m7) == [])
    #expect(sequencer.accept(m8) == [])
    // pending {6,7,8,9} exceeds maxPending(3) -> skip ahead past the 4/5 gap entirely
    #expect(sequencer.accept(m9) == [m6, m7, m8, m9])
    #expect(sequencer.nextIndex == 10)

    // chunk 4 was skipped over and is now older than nextIndex -> dropped
    #expect(sequencer.accept(m4) == [])
}

@Test func sequencerFlushReturnsAllPendingInIndexOrder() {
    var sequencer = WatchChunkSequencer()
    let m1 = fixtureMeta(index: 1)
    let m2 = fixtureMeta(index: 2)

    #expect(sequencer.accept(m2) == [])
    #expect(sequencer.accept(m1) == [])
    #expect(sequencer.flush() == [m1, m2])
    #expect(sequencer.flush() == [])
}

@Test func sequencerIgnoresChunksFromADifferentSessionAndKeepsStateUnchanged() {
    var sequencer = WatchChunkSequencer()
    let a0 = fixtureMeta(session: "session-a", index: 0)
    let b0 = fixtureMeta(session: "session-b", index: 0)

    #expect(sequencer.accept(a0) == [a0])
    #expect(sequencer.accept(b0) == [])
    #expect(sequencer.nextIndex == 1)

    // the ignored chunk must not have been buffered either
    #expect(sequencer.flush() == [])
}

// MARK: - 時間窓

@Test func timeWindowWaitsInsteadOfSkippingByCount() {
    var sequencer = WatchChunkSequencer(maxPending: 3, maxPendingAgeMS: 120_000)
    for index in 1...5 {
        let result = sequencer.accept(fixtureMeta(index: index), atMS: Int64(index) * 1_000)
        #expect(result.ready.isEmpty)
        #expect(result.skipped.isEmpty)
    }
    #expect(sequencer.nextIndex == 0)
}

@Test func timeWindowSkipsAfterTwoMinutesAndReportsTheGap() {
    var sequencer = WatchChunkSequencer(maxPending: 3, maxPendingAgeMS: 120_000)
    let m3 = fixtureMeta(index: 3)
    #expect(sequencer.accept(m3, atMS: 0).ready.isEmpty)
    let early = sequencer.tick(atMS: 119_999)
    #expect(early.ready.isEmpty)
    #expect(early.skipped.isEmpty)
    let late = sequencer.tick(atMS: 120_000)
    #expect(late.ready == [m3])
    #expect(late.skipped == [0, 1, 2])
    #expect(sequencer.nextIndex == 4)
}

@Test func timeWindowSkipsOnAcceptToo() {
    var sequencer = WatchChunkSequencer(maxPending: 3, maxPendingAgeMS: 120_000)
    let m2 = fixtureMeta(index: 2)
    let m3 = fixtureMeta(index: 3)
    #expect(sequencer.accept(m3, atMS: 0).ready.isEmpty)
    let result = sequencer.accept(m2, atMS: 130_000)
    #expect(result.ready == [m2, m3])
    #expect(result.skipped == [0, 1])
}

@Test func tickReleasesWithoutANewChunk() {
    var sequencer = WatchChunkSequencer(maxPending: 3, maxPendingAgeMS: 1_000)
    let m1 = fixtureMeta(index: 1)
    #expect(sequencer.accept(m1, atMS: 0).ready.isEmpty)
    #expect(sequencer.tick(atMS: 1_000).ready == [m1])
}

@Test func tickWithNothingPendingIsEmpty() {
    var sequencer = WatchChunkSequencer(maxPending: 3, maxPendingAgeMS: 1_000)
    let result = sequencer.tick(atMS: 999_999)
    #expect(result.ready.isEmpty)
    #expect(result.skipped.isEmpty)
}

@Test func resumesFromTheLedgerIndex() {
    var sequencer = WatchChunkSequencer(maxPending: 3, maxPendingAgeMS: 120_000, startingAt: 5)
    #expect(sequencer.accept(fixtureMeta(index: 4), atMS: 0).ready.isEmpty)
    let m5 = fixtureMeta(index: 5)
    #expect(sequencer.accept(m5, atMS: 0).ready == [m5])
}

@Test func countRuleReportsSkippedIndexesThroughTheNewAccept() {
    var sequencer = WatchChunkSequencer(maxPending: 1)
    #expect(sequencer.accept(fixtureMeta(index: 2), atMS: 0).skipped.isEmpty)
    let result = sequencer.accept(fixtureMeta(index: 3), atMS: 0)
    #expect(result.ready.map(\.index) == [2, 3])
    #expect(result.skipped == [0, 1])
}
