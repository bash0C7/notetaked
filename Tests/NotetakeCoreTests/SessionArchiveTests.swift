import Foundation
import Testing
@testable import NotetakeCore

private let device = "mac1"
private let prefix = "2026-10-06_100000"

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func info(_ output: URL) -> CaptureSessionInfo {
    CaptureSessionInfo(outputDirectory: output.path, device: device, deviceName: "山田太郎のMac", owner: "山田太郎")
}

private func provisional(_ text: String, start: Int64 = 1_000, source: Source = .mic, deviceID: String = device) -> Segment {
    Segment(
        id: UUID(), session: prefix, seq: 1, device: deviceID, deviceName: deviceID, owner: "山田太郎", platform: .mac,
        source: source, input: .test, start: start, end: start + 1_000, text: text)
}

private func result(run: Int = 1) -> FinalizeResult {
    func utterance(_ speaker: String, _ start: Int64, _ text: String) -> FinalizeUtterance {
        FinalizeUtterance(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", Int(start / 1_000)))")!,
            speaker: speaker, start: start, end: start + 1_000, text: text, confidence: nil, levelDBFS: -20,
            input: .test)
    }
    return FinalizeResult(
        run: run,
        sources: [
            FinalizeSourceResult(
                source: .mic,
                utterances: [utterance("S1", 1_000, "一人目"), utterance("S2", 5_000, "二人目")],
                speakers: [
                    FinalizeSpeaker(local: "S1", seconds: 4, excerpt: "一人目", firstStartMS: 1_000, centroid: [1, 0]),
                    FinalizeSpeaker(local: "S2", seconds: 2, excerpt: "二人目", firstStartMS: 5_000, centroid: [0, 1]),
                ])
        ])
}

private func seedProvisional(_ archive: SessionArchive, in output: URL) async throws {
    await archive.begin(prefix: prefix, in: output)
    try await archive.appendLive(.session(SessionRecord(id: prefix, started: 500, owner: "山田太郎")))
    try await archive.appendLive(.segment(provisional("暫定の発話")))
    try await archive.endCurrent(endedMS: 9_000)
}

private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

@Test func endingTheCurrentSessionWritesSessionEndAndTheProvisionalFinal() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)

    try await seedProvisional(archive, in: output)

    #expect(await archive.currentPrefix == nil)
    let records = try await archive.readRecords(prefix: prefix, in: output)
    #expect(records.contains(.sessionEnd(SessionEndRecord(ended: 9_000))))
    #expect(try text(SessionFiles.finalURL(prefix: prefix, directory: output)).contains("暫定の発話"))
    #expect(try text(output.appendingPathComponent("\(prefix).live.txt")) == "暫定の発話\n")
}

@Test func abandoningTheCurrentSessionWritesNoSessionEndAndNoFinal() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    await archive.begin(prefix: prefix, in: output)
    try await archive.appendLive(.session(SessionRecord(id: prefix, started: 500, owner: "山田太郎")))

    await archive.abandonCurrent()

    #expect(await archive.currentPrefix == nil)
    let records = try await archive.readRecords(prefix: prefix, in: output)
    #expect(!records.contains { if case .sessionEnd = $0 { return true } else { return false } })
    #expect(!FileManager.default.fileExists(atPath: SessionFiles.finalURL(prefix: prefix, directory: output).path))
}

@Test func importWritesFinalSpeakersAndFinalMarkdownAndIsIdempotent() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)

    let first = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 1)
    #expect(!first.skipped)
    #expect(first.event.run == 1)
    #expect(first.event.speakers.map(\.id) == ["s1", "s2"])

    let markdown = try text(SessionFiles.finalURL(prefix: prefix, directory: output))
    #expect(markdown.contains("**話者1**"))
    #expect(markdown.contains("**話者2**"))
    #expect(!markdown.contains("暫定の発話"))
    #expect(try SpeakersFile.read(from: SpeakersFile.url(prefix: prefix, directory: output))?.run == 1)
    #expect(try text(output.appendingPathComponent("\(prefix).live.txt")) == "暫定の発話\n")

    let timedBefore = try text(SessionFiles.timedURL(prefix: prefix, directory: output))
    let second = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 2)
    #expect(second.skipped)
    #expect(try text(SessionFiles.timedURL(prefix: prefix, directory: output)) == timedBefore)
    #expect(try text(SessionFiles.finalURL(prefix: prefix, directory: output)) == markdown)
}

@Test func importCompletesAfterACrashBetweenTheSpeakersFileAndTheAppend() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)
    let plan = FinalizeImport.plan(result: result(), info: info(output), prefix: prefix, previous: nil, receivedAt: 1)
    try plan.speakers.write(to: SpeakersFile.url(prefix: prefix, directory: output))

    let outcome = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 1)

    #expect(!outcome.skipped)
    let records = try await archive.readRecords(prefix: prefix, in: output)
    #expect(FinalizeImport.isImported(run: 1, in: records))
    #expect(Reconciler.fold(records).map(\.speaker) == ["話者1", "話者2"])
}

@Test func tornFinalSegmentsWithoutFinalizedAreNotRenderedAndImportRepairsThem() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)
    let plan = FinalizeImport.plan(result: result(), info: info(output), prefix: prefix, previous: nil, receivedAt: 1)
    let withoutFinalized = Array(plan.records.dropLast())
    try TimedFile.append(withoutFinalized, to: SessionFiles.timedURL(prefix: prefix, directory: output))
    try await archive.renderFinal(prefix: prefix, in: output)
    #expect(try text(SessionFiles.finalURL(prefix: prefix, directory: output)).contains("暫定の発話"))

    _ = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 1)
    let markdown = try text(SessionFiles.finalURL(prefix: prefix, directory: output))
    #expect(!markdown.contains("暫定の発話"))
    #expect(markdown.components(separatedBy: "一人目").count == 2)
}

@Test func renameAndMergeRecordTheRunAndRewriteTheFiles() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)
    _ = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 1)

    let renamed = try await archive.renameSpeaker(
        prefix: prefix, in: output, device: device, id: "s2", name: "佐藤花子")
    #expect(renamed.speakers.map(\.name) == [nil, "佐藤花子"])
    #expect(try text(SessionFiles.finalURL(prefix: prefix, directory: output)).contains("**佐藤花子**"))

    let merged = try await archive.mergeSpeakers(prefix: prefix, in: output, device: device, from: "s2", into: "s1")
    #expect(merged.speakers.map(\.id) == ["s1"])
    #expect(merged.speakers[0].name == "佐藤花子")
    let markdown = try text(SessionFiles.finalURL(prefix: prefix, directory: output))
    #expect(!markdown.contains("話者1"))
    #expect(markdown.components(separatedBy: "**佐藤花子**").count == 3)

    let records = try await archive.readRecords(prefix: prefix, in: output)
    #expect(records.contains(.speakerName(SpeakerNameRecord(speaker: "s2", name: "佐藤花子", run: 1))))
    #expect(records.contains(.speakerMerge(SpeakerMergeRecord(run: 1, from: "s2", into: "s1"))))
}

@Test func editsRejectUnknownSpeakersUnfinalizedAndRecordingSessions() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)

    await #expect(throws: SessionArchiveError.notFinalized(prefix)) {
        _ = try await archive.renameSpeaker(prefix: prefix, in: output, device: device, id: "s1", name: "x")
    }
    _ = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 1)
    await #expect(throws: SessionArchiveError.unknownSpeaker("s9")) {
        _ = try await archive.renameSpeaker(prefix: prefix, in: output, device: device, id: "s9", name: "x")
    }
    await #expect(throws: SessionArchiveError.unknownSpeaker("s1")) {
        _ = try await archive.mergeSpeakers(prefix: prefix, in: output, device: device, from: "s1", into: "s1")
    }
    await archive.begin(prefix: prefix, in: output)
    await #expect(throws: SessionArchiveError.recording(prefix)) {
        _ = try await archive.renameSpeaker(prefix: prefix, in: output, device: device, id: "s1", name: "x")
    }
}

@Test func repairBringsTheSpeakersFileBackInLineWithTimed() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)
    _ = try await archive.importFinalize(result: result(), info: info(output), prefix: prefix, receivedAt: 1)
    try TimedFile.append(
        [.speakerName(SpeakerNameRecord(speaker: "s1", name: "山田太郎", run: 1))],
        to: SessionFiles.timedURL(prefix: prefix, directory: output))

    let event = try #require(try await archive.repair(prefix: prefix, in: output, device: device))

    #expect(event.speakers.map(\.name) == ["山田太郎", nil])
    #expect(try SpeakersFile.read(from: SpeakersFile.url(prefix: prefix, directory: output))?.speakers[0].name == "山田太郎")
    #expect(try text(SessionFiles.finalURL(prefix: prefix, directory: output)).contains("**山田太郎**"))
    await #expect(throws: SessionArchiveError.missingTimed("missing-session")) {
        _ = try await archive.repair(prefix: "missing-session", in: output, device: device)
    }
}

@Test func lateSegmentsAreAppendedToAPastSessionAndOrphansAreKept() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)

    try await archive.appendAndRender(
        [.segment(provisional("遅れて届いた発話", start: 20_000, deviceID: "iphone1"))], prefix: prefix, in: output)
    #expect(try text(SessionFiles.finalURL(prefix: prefix, directory: output)).contains("遅れて届いた発話"))

    try await archive.appendOrphan(provisional("どこにも入らない", deviceID: "iphone1"), in: output)
    #expect(try text(output.appendingPathComponent("orphans.jsonl")).contains("どこにも入らない"))
}

@Test func sessionListUsesSessionEndAndRereadsOnlyChangedFiles() async throws {
    let output = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    try await seedProvisional(archive, in: output)

    var spans = await archive.sessions(in: output)
    #expect(spans == [SessionSpan(prefix: prefix, startMS: 500, endMS: 9_000)])

    await archive.begin(prefix: prefix, in: output)
    spans = await archive.sessions(in: output)
    #expect(spans.first?.endMS == nil)
    try await archive.endCurrent(endedMS: 9_500)
    spans = await archive.sessions(in: output)
    #expect(spans.first?.endMS == 9_500)

    // session_endの無い従来の収録は、全発話のendの最大値を終了にする
    let legacy = [
        Record.session(SessionRecord(id: "old", started: 100, owner: "山田太郎")),
        Record.segment(provisional("古い収録", start: 200)),
    ]
    try TimedFile.append(legacy, to: SessionFiles.timedURL(prefix: "old", directory: output))
    spans = await archive.sessions(in: output)
    #expect(spans.map(\.prefix) == ["old", prefix])
    #expect(spans.first?.endMS == 1_200)
}
