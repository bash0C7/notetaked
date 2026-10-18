import Foundation
import Testing
@testable import NotetakeCore

private func meta(index: Int = 4, full: Bool = true) -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: "1700000000000", index: index, startAtMS: 1_700_000_080_000, sampleRate: 16000,
        device: "watch-abc", deviceName: "Watch", owner: "小芝",
        maxDBFS: full ? -12.5 : nil, meanDBFS: full ? -30 : nil,
        batteryLevel: full ? 0.8 : nil, maxQueueDepth: full ? 2 : nil,
        durationMS: full ? 20_000 : nil, isFinal: full ? true : nil)
}

@Test func receiptCopiesTheChunkSummary() {
    let receipt = WatchChunkReceipt(metadata: meta(), receivedAtMS: 1_700_000_100_000)
    #expect(receipt.device == "watch-abc")
    #expect(receipt.session == "1700000000000")
    #expect(receipt.index == 4)
    #expect(receipt.startAtMS == 1_700_000_080_000)
    #expect(receipt.durationMS == 20_000)
    #expect(receipt.isFinal == true)
    #expect(receipt.batteryLevel == 0.8)
    #expect(receipt.maxDBFS == -12.5)
    #expect(receipt.maxQueueDepth == 2)
    #expect(receipt.receivedAtMS == 1_700_000_100_000)
}

@Test func receiptRoundTripsThroughALine() throws {
    let receipt = WatchChunkReceipt(metadata: meta(), receivedAtMS: 5)
    let line = try receipt.encodedLine()
    #expect(!line.contains("\n"))
    #expect(line.contains("\"start_at_ms\""))
    #expect(line.contains("\"is_final\""))
    #expect(WatchChunkReceipt.decodeLines(line + "\n") == [receipt])
}

@Test func receiptLinesSkipBrokenLines() throws {
    let a = try WatchChunkReceipt(metadata: meta(index: 1), receivedAtMS: 1).encodedLine()
    let b = try WatchChunkReceipt(metadata: meta(index: 2), receivedAtMS: 2).encodedLine()
    let text = a + "\n{broken\n\n" + b + "\n"
    #expect(WatchChunkReceipt.decodeLines(text).map(\.index) == [1, 2])
}

@Test func receiptOmitsNilFields() throws {
    let line = try WatchChunkReceipt(metadata: meta(full: false), receivedAtMS: 1).encodedLine()
    #expect(!line.contains("duration_ms"))
    #expect(!line.contains("max_dbfs"))
    #expect(!line.contains("battery_level"))
    #expect(!line.contains("is_final"))
}
