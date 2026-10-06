import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("finalize-\(UUID().uuidString)")
}

@Test func recoveryQueuesOnlyUnfinalizedSessionsOldestFirst() {
    let facts = [
        RawSessionFacts(prefix: "2026-10-06_120000"),
        RawSessionFacts(prefix: "2026-10-06_100000"),
        RawSessionFacts(prefix: "2026-10-06_110000", latestFinalizedRun: 1),
        RawSessionFacts(prefix: "2026-10-06_130000", failureCount: 4),
        RawSessionFacts(prefix: "2026-10-06_140000", failureCount: 3),
        RawSessionFacts(prefix: "2026-10-06_150000", hasSessionInfo: false),
        RawSessionFacts(prefix: "2026-10-06_160000", timedExists: false),
        RawSessionFacts(prefix: "2026-10-06_170000"),
    ]
    let actions = FinalizeRecovery.actions(facts: facts, recordingPrefix: "2026-10-06_170000")
    #expect(
        actions == [
            .finalize(prefix: "2026-10-06_100000"),
            .finalize(prefix: "2026-10-06_120000"),
            .finalize(prefix: "2026-10-06_140000"),
        ])
}

@Test func recoveryImportsAReadyResultWithoutFinalizingAgain() {
    let facts = [
        RawSessionFacts(prefix: "a", resultRun: 1),
        RawSessionFacts(prefix: "b", latestFinalizedRun: 1, resultRun: 2),
        RawSessionFacts(prefix: "c", latestFinalizedRun: 2, resultRun: 2),
        RawSessionFacts(prefix: "d", resultRun: 1, failureCount: 4),
    ]
    #expect(
        FinalizeRecovery.actions(facts: facts, recordingPrefix: nil) == [
            .importResult(prefix: "a", run: 1),
            .importResult(prefix: "b", run: 2),
            .importResult(prefix: "d", run: 1),
        ])
}

@Test func recoveryRendersAFinalizedSessionWhoseFinalIsStale() {
    let facts = [
        RawSessionFacts(prefix: "a", latestFinalizedRun: 1, finalIsStale: true),
        RawSessionFacts(prefix: "b", latestFinalizedRun: 1, finalIsStale: false),
    ]
    #expect(FinalizeRecovery.actions(facts: facts, recordingPrefix: nil) == [.render(prefix: "a")])
}

@Test func recoveryReportsGivenUpSessionsOnly() {
    let facts = [
        RawSessionFacts(prefix: "a", failureCount: 4),
        RawSessionFacts(prefix: "b", failureCount: 3),
        RawSessionFacts(prefix: "c", latestFinalizedRun: 1, failureCount: 4),
        RawSessionFacts(prefix: "d", resultRun: 1, failureCount: 4),
        RawSessionFacts(prefix: "e", failureCount: 4),
    ]
    #expect(FinalizeRecovery.gaveUp(facts: facts, recordingPrefix: "e") == ["a"])
}

@Test func recoveryScanReadsTheFactsFromDisk() throws {
    let base = temporaryDirectory()
    let output = temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.removeItem(at: output)
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func raw(_ prefix: String) -> URL {
        CaptureSessionPaths.sessionDirectory(prefix: prefix, baseTemporaryDirectory: base)
    }
    let info = CaptureSessionInfo(outputDirectory: output.path, device: "mac1", deviceName: "山田太郎のMac", owner: "山田太郎")
    let finalizedRecords: [Record] = [
        .session(SessionRecord(id: "done", started: 1, owner: "山田太郎")),
        .finalized(FinalizedRecord(run: 3, device: "mac1", sources: [.mic])),
    ]
    try JSONFile.write(info, to: CaptureSessionPaths.sessionInfoURL(sessionDirectory: raw("done")))
    try Data(finalizedRecords.map { try NDJSON.encode($0) + "\n" }.joined().utf8).write(
        to: SessionFiles.timedURL(prefix: "done", directory: output))

    try JSONFile.write(info, to: CaptureSessionPaths.sessionInfoURL(sessionDirectory: raw("pending")))
    try Data(#"{"id":"pending","owner":"山田太郎","started":1,"t":"session"}"#.utf8).write(
        to: SessionFiles.timedURL(prefix: "pending", directory: output))
    try FinalizeAttempts.write(2, sessionDirectory: raw("pending"))
    try JSONFile.write(
        FinalizeResult(run: 1, sources: []),
        to: CaptureSessionPaths.finalizeResultURL(sessionDirectory: raw("pending")))

    try FileManager.default.createDirectory(at: raw("orphan"), withIntermediateDirectories: true)

    let scanned = FinalizeRecovery.scan(rawBase: base)
    #expect(scanned.errors.isEmpty)
    #expect(scanned.facts.map(\.prefix) == ["done", "orphan", "pending"])
    #expect(scanned.facts[0].latestFinalizedRun == 3)
    #expect(scanned.facts[0].finalIsStale)
    #expect(!scanned.facts[1].hasSessionInfo)
    #expect(scanned.facts[2].failureCount == 2)
    #expect(scanned.facts[2].resultRun == 1)
    #expect(scanned.facts[2].latestFinalizedRun == nil)
}
