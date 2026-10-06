import Foundation
import Testing
import NotetakeCore
@testable import notetaked

private let deviceID = "mac1"

private extension InputDevice {
    static let test = InputDevice(name: "外部マイク", uid: "external", spatial: false)
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [Event] = []
    private var storedDelays: [TimeInterval] = []
    private var storedRuns: [(prefix: String, run: Int, speakers: Int?)] = []
    private var active = 0
    private(set) var maxActive = 0
    private var actualPrefixes: [String?] = []

    var events: [Event] { lock.withLock { storedEvents } }
    var delays: [TimeInterval] { lock.withLock { storedDelays } }
    var runs: [(prefix: String, run: Int, speakers: Int?)] { lock.withLock { storedRuns } }

    func add(_ event: Event) { lock.withLock { storedEvents.append(event) } }
    func addDelay(_ delay: TimeInterval) { lock.withLock { storedDelays.append(delay) } }
    func addRun(_ prefix: String, _ run: Int, _ speakers: Int?) { lock.withLock { storedRuns.append((prefix, run, speakers)) } }
    func enter() { lock.withLock { active += 1; maxActive = max(maxActive, active) } }
    func leave() { lock.withLock { active -= 1 } }
    func setActualPrefixes(_ prefixes: [String?]) { lock.withLock { actualPrefixes = prefixes } }
    func nextActualPrefix() -> String?? {
        lock.withLock { actualPrefixes.isEmpty ? nil : .some(actualPrefixes.removeFirst()) }
    }

    func states(of prefix: String) -> [FinalizePhase] {
        events.compactMap { event in
            if case .finalizeState(let state) = event, state.prefix == prefix { return state.phase }
            return nil
        }
    }

    func logs() -> [String] {
        events.compactMap { event in
            if case .log(let message) = event { return message }
            return nil
        }
    }

    func errors() -> [String] {
        events.compactMap { event in
            if case .error(let message) = event { return message }
            return nil
        }
    }
}

private struct Harness {
    let output: URL
    let rawBase: URL
    let archive = SessionArchive(timeZone: TimeZone(identifier: "UTC")!)
    let log = Log()

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
        output = root.appendingPathComponent("out")
        rawBase = root.appendingPathComponent("raw")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }

    func sessionDirectory(_ prefix: String) -> URL {
        CaptureSessionPaths.sessionDirectory(prefix: prefix, baseTemporaryDirectory: rawBase)
    }

    /// 終わった収録（暫定の発話が1件）と、その生音声ディレクトリの`session.json`を用意する
    func seedSession(_ prefix: String) async throws {
        await archive.begin(prefix: prefix, in: output)
        try await archive.appendLive(.session(SessionRecord(id: prefix, started: 500, owner: "山田太郎")))
        try await archive.appendLive(
            .segment(
                Segment(
                    id: UUID(), session: prefix, seq: 1, device: deviceID, deviceName: "n", owner: "山田太郎",
                    platform: .mac, source: .mic, input: .test, start: 1_000, end: 2_000, text: "暫定の発話")))
        try await archive.endCurrent(endedMS: 9_000)
        try JSONFile.write(
            CaptureSessionInfo(outputDirectory: output.path, device: deviceID, deviceName: "山田太郎のMac", owner: "山田太郎"),
            to: CaptureSessionPaths.sessionInfoURL(sessionDirectory: sessionDirectory(prefix)))
    }

    /// 2人の話者がいる結果を、子processの代わりに書く
    func writeResult(prefix: String, run: Int) throws {
        func utterance(_ index: Int, _ speaker: String, _ start: Int64, _ text: String) -> FinalizeUtterance {
            FinalizeUtterance(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!, speaker: speaker, start: start,
                end: start + 1_000, text: text, confidence: nil, levelDBFS: -20, input: .test)
        }
        let result = FinalizeResult(
            run: run,
            sources: [
                FinalizeSourceResult(
                    source: .mic, utterances: [utterance(1, "S1", 1_000, "一人目"), utterance(2, "S2", 5_000, "二人目")],
                    speakers: [
                        FinalizeSpeaker(local: "S1", seconds: 4, excerpt: "一人目", firstStartMS: 1_000, centroid: [1, 0]),
                        FinalizeSpeaker(local: "S2", seconds: 2, excerpt: "二人目", firstStartMS: 5_000, centroid: [0, 1]),
                    ])
            ])
        try JSONFile.write(result, to: CaptureSessionPaths.finalizeResultURL(sessionDirectory: sessionDirectory(prefix)))
    }

    func queue(
        runChild: (@Sendable (String, Int, Int?, @escaping @Sendable (String) -> Void) async throws -> Void)? = nil,
        sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) -> FinalizeQueue {
        let harness = self
        let log = log
        return FinalizeQueue(
            dependencies: FinalizeQueue.Dependencies(
                archive: archive, deviceID: deviceID, rawBase: rawBase,
                runChild: { directory, run, speakers, onLine in
                    let prefix = directory.lastPathComponent
                    log.addRun(prefix, run, speakers)
                    if let runChild {
                        try await runChild(prefix, run, speakers, onLine)
                    } else {
                        onLine("[DEBUG] [FluidAudio.OfflineDiarizer] noise")
                        onLine("finalize-progress mic transcribe 50")
                        onLine("finalize: 完了 run \(run)")
                        try harness.writeResult(prefix: prefix, run: run)
                    }
                },
                readActual: {
                    guard let next = log.nextActualPrefix() else { return nil }
                    return CaptureActualState(
                        pid: 1, prefix: next, sources: [], updated: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
                },
                now: { Date() },
                sleep: sleep ?? { delay in
                    log.addDelay(delay)
                    try await Task.sleep(for: .milliseconds(5))
                },
                emit: { log.add($0) }))
    }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

@Test func queueFinalizesAnEndedSessionAndPublishesStatesAndTheFinalizedEvent() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let queue = harness.queue()

    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }

    #expect(harness.log.states(of: "p1") == [.waiting, .running, .running, .finalized])
    #expect(harness.log.runs.map(\.run) == [1])
    let finalized = harness.log.events.compactMap { event -> FinalizedEvent? in
        if case .finalized(let finalized) = event { return finalized }
        return nil
    }
    #expect(finalized.map(\.prefix) == ["p1"])
    #expect(finalized.first?.speakers.map(\.id) == ["s1", "s2"])
    #expect(try text(SessionFiles.finalURL(prefix: "p1", directory: harness.output)).contains("**話者1**"))
    #expect(await queue.state(of: "p1")?.run == 1)
    await waitUntil { harness.log.logs().contains("p1: finalize: 完了 run 1") }
    #expect(harness.log.logs().contains("p1: finalize: 完了 run 1"))
    #expect(!harness.log.logs().contains { $0.contains("DEBUG") })
}

@Test func queueWaitsWhileCaptureDaemonStillWritesThePrefix() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    harness.log.setActualPrefixes(["p1", "p1", "p2"])
    let queue = harness.queue()

    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }

    #expect(harness.log.delays.count == 2)
    #expect(harness.log.runs.count == 1)
}

@Test func queueRunsOneJobAtATime() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    try await harness.seedSession("p2")
    let log = harness.log
    let queue = harness.queue(runChild: { prefix, run, _, _ in
        log.enter()
        defer { log.leave() }
        try await Task.sleep(for: .milliseconds(40))
        try harness.writeResult(prefix: prefix, run: run)
    })

    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await queue.enqueue(.init(prefix: "p2", speakers: nil))
    await waitUntil { await queue.state(of: "p2")?.phase == .finalized }

    #expect(log.maxActive == 1)
    #expect(harness.log.runs.map(\.prefix) == ["p1", "p2"])
}

@Test func failuresRetryAtOneTenAndSixtyMinutesThenGiveUp() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let log = harness.log
    let queue = harness.queue(
        runChild: { _, _, _, _ in throw FinalizeProcessError.exited(status: 1, stderrTail: "model") },
        sleep: { delay in
            log.addDelay(delay)
            try await Task.sleep(for: .milliseconds(5))
        })

    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .gaveUp }

    #expect(log.delays.filter { $0 >= 60 } == [60, 600, 3_600])
    #expect(log.runs.count == 4)
    #expect(try FinalizeAttempts.read(sessionDirectory: harness.sessionDirectory("p1")) == 4)
    #expect(log.states(of: "p1").filter { $0 == .failed }.count == 3)
    #expect(log.errors().contains { $0.contains("諦めました") })
    #expect(await queue.state(of: "p1")?.detail?.contains("model") == true)
}

@Test func successClearsTheFailureCount() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let calls = Counter()
    let queue = harness.queue(runChild: { prefix, run, _, _ in
        if calls.next() == 1 { throw FinalizeProcessError.stalled(after: 300) }
        try harness.writeResult(prefix: prefix, run: run)
    })

    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }

    #expect(try FinalizeAttempts.read(sessionDirectory: harness.sessionDirectory("p1")) == 0)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@Test func manualRefinalizeUsesTheNextRunKeepsNamesAndDoesNotCountFailures() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let queue = harness.queue()
    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }
    _ = try await harness.archive.renameSpeaker(
        prefix: "p1", in: harness.output, device: deviceID, id: "s1", name: "佐藤花子")

    await queue.refinalize(prefix: "p1", speakers: 2)
    await waitUntil { await queue.state(of: "p1")?.run == 2 }

    #expect(harness.log.runs.map(\.run) == [1, 2])
    #expect(harness.log.runs.last?.speakers == 2)
    #expect(try text(SessionFiles.finalURL(prefix: "p1", directory: harness.output)).contains("**佐藤花子**"))
    #expect(harness.log.logs().contains { $0.contains("名前を引き継ぎました s1") })
    let records = try await harness.archive.readRecords(prefix: "p1", in: harness.output)
    #expect(Reconciler.fold(records).map(\.speaker) == ["佐藤花子", "話者2"])
}

@Test func manualFailureKeepsTheEarlierFinalizationAndSchedulesNothing() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let calls = Counter()
    let log = harness.log
    let queue = harness.queue(
        runChild: { prefix, run, _, _ in
            if calls.next() == 2 { throw FinalizeProcessError.exited(status: 1, stderrTail: "x") }
            try harness.writeResult(prefix: prefix, run: run)
        },
        sleep: { delay in
            log.addDelay(delay)
            try await Task.sleep(for: .milliseconds(5))
        })
    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }

    await queue.refinalize(prefix: "p1", speakers: nil)
    await waitUntil { log.errors().contains { $0.contains("確定し直しに失敗") } }
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }

    #expect(await queue.state(of: "p1")?.run == 1)
    #expect(try FinalizeAttempts.read(sessionDirectory: harness.sessionDirectory("p1")) == 0)
    #expect(log.delays.filter { $0 >= 60 }.isEmpty)
}

@Test func refinalizeWithoutRawAudioReportsAnError() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    let queue = harness.queue()

    await queue.refinalize(prefix: "gone", speakers: nil)

    #expect(harness.log.errors().contains { $0.contains("生音声が残っていません") })
    #expect(await queue.state(of: "gone") == nil)
}

@Test func recoveryImportsAReadyResultWithoutRunningTheChildAndReportsGivenUpSessions() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    try harness.writeResult(prefix: "p1", run: 1)
    let queue = harness.queue()

    await queue.recover(actions: [.importResult(prefix: "p1", run: 1)], gaveUp: ["p0"])
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }

    #expect(harness.log.runs.isEmpty)
    #expect(await queue.state(of: "p0")?.phase == .gaveUp)
    #expect(try SpeakersFile.read(from: SpeakersFile.url(prefix: "p1", directory: harness.output))?.run == 1)
}

@Test func recoveryRenderRewritesTheFinalOfAFinalizedSession() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let queue = harness.queue()
    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .finalized }
    try? FileManager.default.removeItem(at: SessionFiles.finalURL(prefix: "p1", directory: harness.output))

    await queue.recover(actions: [.render(prefix: "p1")], gaveUp: [])

    #expect(try text(SessionFiles.finalURL(prefix: "p1", directory: harness.output)).contains("**話者1**"))
}

@Test func shutdownStopsPendingRetriesWithoutCountingTheInterruptedRun() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let queue = harness.queue(runChild: { _, _, _, _ in
        try await Task.sleep(for: .seconds(30))
    })
    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .running }

    await queue.shutdown()

    #expect(try FinalizeAttempts.read(sessionDirectory: harness.sessionDirectory("p1")) == 0)
    #expect(!harness.log.states(of: "p1").contains(.failed))
}
