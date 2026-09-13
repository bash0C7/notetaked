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

// MARK: - WatchChunkMetadata

@Test func metadataRoundTripsThroughDictionary() {
    let meta = fixtureMeta()
    let restored = WatchChunkMetadata(metadata: meta.metadata)
    #expect(restored == meta)
}

@Test func metadataDictionaryUsesSnakeCaseKeys() {
    let meta = fixtureMeta()
    let dict = meta.metadata
    #expect(dict["session"] as? String == meta.session)
    #expect(dict["index"] as? Int == meta.index)
    #expect(dict["start_at_ms"] as? Int64 == meta.startAtMS)
    #expect(dict["sample_rate"] as? Double == meta.sampleRate)
    #expect(dict["device"] as? String == meta.device)
    #expect(dict["device_name"] as? String == meta.deviceName)
    #expect(dict["owner"] as? String == meta.owner)
}

@Test func metadataRoundTripsWithStartAtMSAsNSNumber() {
    let meta = fixtureMeta()
    var dict = meta.metadata
    dict["start_at_ms"] = NSNumber(value: meta.startAtMS)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored == meta)
}

@Test func metadataRoundTripsWithStartAtMSAsDouble() {
    let meta = fixtureMeta()
    var dict = meta.metadata
    dict["start_at_ms"] = Double(meta.startAtMS)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored == meta)
}

@Test func metadataRoundTripsWithStartAtMSAsInt() {
    let meta = fixtureMeta()
    var dict = meta.metadata
    dict["start_at_ms"] = Int(meta.startAtMS)
    let restored = WatchChunkMetadata(metadata: dict)
    #expect(restored == meta)
}

@Test func metadataInitFailsWhenKeyIsMissing() {
    var dict = fixtureMeta().metadata
    dict.removeValue(forKey: "owner")
    #expect(WatchChunkMetadata(metadata: dict) == nil)
}

@Test func metadataInitFailsWhenTypeIsWrong() {
    var dict = fixtureMeta().metadata
    dict["index"] = "0" // should be Int, not String
    #expect(WatchChunkMetadata(metadata: dict) == nil)
}

@Test func metadataInitFailsWhenStartAtMSIsNotNumeric() {
    var dict = fixtureMeta().metadata
    dict["start_at_ms"] = "not-a-number"
    #expect(WatchChunkMetadata(metadata: dict) == nil)
}

@Test func metadataInitFailsOnEmptyDictionary() {
    #expect(WatchChunkMetadata(metadata: [:]) == nil)
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
