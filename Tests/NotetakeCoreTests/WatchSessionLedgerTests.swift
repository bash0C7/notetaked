import Foundation
import Testing
@testable import NotetakeCore

@Test func originComesFromTheSessionString() {
    let ledger = WatchSessionLedger()
    #expect(ledger.originMS(session: "1700000000000") == 1_700_000_000_000)
    #expect(ledger.originMS(session: "session-a") == nil)
}

@Test func processedIndexesSurviveEncoding() throws {
    var ledger = WatchSessionLedger()
    ledger.markProcessed(session: "100", index: 0, atMS: 10)
    ledger.markProcessed(session: "100", index: 2, atMS: 20)
    ledger.markFinished(session: "100", atMS: 30)
    let decoded = try JSONDecoder().decode(WatchSessionLedger.self, from: JSONEncoder().encode(ledger))
    #expect(decoded == ledger)
    #expect(decoded.isProcessed(session: "100", index: 2))
    #expect(!decoded.isProcessed(session: "100", index: 1))
    #expect(!decoded.isProcessed(session: "200", index: 0))
    #expect(decoded.isFinished(session: "100"))
}

@Test func missingIndexesListsGaps() {
    var ledger = WatchSessionLedger()
    for index in [0, 1, 3] { ledger.markProcessed(session: "100", index: index, atMS: 1) }
    #expect(ledger.missingIndexes(session: "100") == [2])
    #expect(ledger.missingIndexes(session: "unknown") == [])
}

@Test func finishedSessionIsRemembered() {
    var ledger = WatchSessionLedger()
    #expect(!ledger.isFinished(session: "100"))
    ledger.markFinished(session: "100", atMS: 5)
    #expect(ledger.isFinished(session: "100"))
}

@Test func pruneDropsOldSessions() {
    var ledger = WatchSessionLedger()
    ledger.markProcessed(session: "old", index: 0, atMS: 100)
    ledger.markProcessed(session: "new", index: 0, atMS: 1_000)
    ledger.prune(olderThanMS: 500)
    #expect(!ledger.isProcessed(session: "old", index: 0))
    #expect(ledger.isProcessed(session: "new", index: 0))
}

@Test func nextIndexContinuesAfterTheHighestProcessed() {
    var ledger = WatchSessionLedger()
    #expect(ledger.nextIndex(session: "100") == 0)
    ledger.markProcessed(session: "100", index: 0, atMS: 1)
    ledger.markProcessed(session: "100", index: 3, atMS: 1)
    #expect(ledger.nextIndex(session: "100") == 4)
}

@Test func freshSessionStreamStartsAtTheSessionOrigin() {
    let ledger = WatchSessionLedger()
    #expect(ledger.streamOriginMS(session: "1000000", firstChunkStartAtMS: 1_500_000) == 1_000_000)
    #expect(ledger.streamOriginMS(session: "x", firstChunkStartAtMS: 1_500_000) == 1_500_000)
}

@Test func rebuiltStreamStartsNearTheFirstChunkInsteadOfTheSessionOrigin() {
    var ledger = WatchSessionLedger()
    ledger.markProcessed(session: "1000000", index: 0, atMS: 1)
    #expect(ledger.streamOriginMS(session: "1000000", firstChunkStartAtMS: 50_000_000) == 49_400_000)
    // 起点はsessionの開始より前にはしない
    #expect(ledger.streamOriginMS(session: "1000000", firstChunkStartAtMS: 1_100_000) == 1_000_000)
}
