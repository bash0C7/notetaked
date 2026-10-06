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

@Test func aFailedRunLeavesTheProvisionalFinalAndReportsTheFailure() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let queue = harness.queue(runChild: { _, _, _, _ in
        throw FinalizeProcessError.exited(status: 1, stderrTail: "model")
    })

    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .gaveUp }

    #expect(harness.log.errors().contains { $0.contains("model") })
    #expect(try text(SessionFiles.finalURL(prefix: "p1", directory: harness.output)).contains("暫定の発話"))
}

@Test func shutdownStopsTheRunningChildWithoutReportingAFailure() async throws {
    let harness = Harness()
    defer { harness.cleanUp() }
    try await harness.seedSession("p1")
    let queue = harness.queue(runChild: { _, _, _, _ in
        try await Task.sleep(for: .seconds(30))
    })
    await queue.enqueue(.init(prefix: "p1", speakers: nil))
    await waitUntil { await queue.state(of: "p1")?.phase == .running }

    await queue.shutdown()

    #expect(!harness.log.states(of: "p1").contains(.gaveUp))
    #expect(harness.log.errors().isEmpty)
}
