import Foundation
import Testing
@testable import NotetakeCore

private func meta(session: String = "1700000000000", index: Int = 0) -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: session, index: index, startAtMS: 1_700_000_000_000 + Int64(index) * 20_000,
        sampleRate: 16000, device: "watch-abc", deviceName: "小芝のApple Watch", owner: "小芝")
}

private func entry(id: String, index: Int = 0, receivedAtMS: Int64 = 0, attempts: Int = 0) -> WatchInboxEntry {
    WatchInboxEntry(
        id: id, metadataJSON: (try? meta(index: index).encodedJSON()) ?? "", receivedAtMS: receivedAtMS,
        attempts: attempts)
}

@Test func entryRoundTripsAndExposesMetadata() throws {
    let original = entry(id: "A", index: 3, receivedAtMS: 42, attempts: 1)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WatchInboxEntry.self, from: data)
    #expect(decoded == original)
    #expect(decoded.metadata == meta(index: 3))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"metadata_json\""))
    #expect(text.contains("\"received_at_ms\""))
}

@Test func entryWithBrokenMetadataHasNilMetadata() {
    let broken = WatchInboxEntry(id: "A", metadataJSON: "{not json", receivedAtMS: 0, attempts: 0)
    #expect(broken.metadata == nil)
}

@Test func exhaustedAfterThreeAttempts() {
    #expect(WatchInboxEntry.maxAttempts == 3)
    #expect(entry(id: "A", attempts: 2).isExhausted == false)
    #expect(entry(id: "A", attempts: 3).isExhausted)
}

@Test func fileNamesUseTheId() {
    #expect(WatchInbox.audioFileName(id: "X") == "X.m4a")
    #expect(WatchInbox.sidecarFileName(id: "X") == "X.json")
}

@Test func recoverableSortsByReceivedTime() {
    let a = entry(id: "A", receivedAtMS: 300)
    let b = entry(id: "B", receivedAtMS: 100)
    let result = WatchInbox.recoverable(
        files: [("A.m4a", 0), ("A.json", 0), ("B.m4a", 0), ("B.json", 0)],
        entries: ["A": a, "B": b], nowMS: 1_000)
    #expect(result.process == [b, a])
    #expect(result.exhausted.isEmpty)
    #expect(result.orphanFiles.isEmpty)
}

@Test func exhaustedEntriesAreNotProcessed() {
    let spent = entry(id: "A", attempts: 3)
    let result = WatchInbox.recoverable(
        files: [("A.m4a", 0), ("A.json", 0)], entries: ["A": spent], nowMS: 1_000)
    #expect(result.process.isEmpty)
    #expect(result.exhausted == [spent])
}

@Test func audioWithoutSidecarIsAnOrphan() {
    let now: Int64 = 1_000_000
    let result = WatchInbox.recoverable(
        files: [("A.m4a", now - WatchInbox.orphanGraceMS)], entries: [:], nowMS: now)
    #expect(result.orphanFiles == ["A.m4a"])
}

@Test func sidecarWithoutAudioIsAnOrphan() {
    let now: Int64 = 1_000_000
    let result = WatchInbox.recoverable(
        files: [("A.json", now - WatchInbox.orphanGraceMS - 1)], entries: ["A": entry(id: "A")], nowMS: now)
    #expect(result.process.isEmpty)
    #expect(result.orphanFiles == ["A.json"])
}

@Test func freshHalfWrittenPairIsNotAnOrphan() {
    let now: Int64 = 1_000_000
    let result = WatchInbox.recoverable(files: [("A.m4a", now - 1_000)], entries: [:], nowMS: now)
    #expect(result.process.isEmpty)
    #expect(result.exhausted.isEmpty)
    #expect(result.orphanFiles.isEmpty)
}

@Test func undecodableSidecarCountsAsHalfAPair() {
    let now: Int64 = 1_000_000
    let old = now - WatchInbox.orphanGraceMS - 1
    let result = WatchInbox.recoverable(
        files: [("A.m4a", old), ("A.json", old)], entries: [:], nowMS: now)
    #expect(result.process.isEmpty)
    #expect(result.orphanFiles == ["A.json", "A.m4a"])
}
