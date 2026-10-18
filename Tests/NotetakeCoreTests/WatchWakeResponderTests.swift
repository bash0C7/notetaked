import Foundation
import Testing
@testable import NotetakeCore

private func progress(
    backlog: Int = 0, unacked: Int = 0, connected: Bool = true, remaining: Double = 25, now: Int64
) -> WatchWakeResponder.Progress {
    .init(intakeBacklog: backlog, unackedSegments: unacked, peerConnected: connected, remainingSeconds: remaining, nowMS: now)
}

// MARK: - responder

@Test func foregroundWakeTakesNoTask() {
    var responder = WatchWakeResponder()
    #expect(responder.woke(appIsActive: true, atMS: 0) == .foreground)
    #expect(responder.holdsTask == false)
}

@Test func backgroundWakeBeginsOneTask() {
    var responder = WatchWakeResponder()
    #expect(responder.woke(appIsActive: false, atMS: 0) == .beginTask)
    #expect(responder.holdsTask)
}

@Test func secondWakeKeepsTheTask() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    #expect(responder.woke(appIsActive: false, atMS: 5_000) == .keepTask)
    #expect(responder.holdsTask)
}

@Test func endsWhenTheDeadlineIsNear() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    #expect(responder.shouldEnd(progress(backlog: 3, unacked: 2, remaining: 5, now: 100)))
    #expect(!responder.shouldEnd(progress(backlog: 3, remaining: 5.1, now: 100)))
}

@Test func keepsWhileTheQueueHasWork() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    #expect(!responder.shouldEnd(progress(backlog: 1, now: 60_000)))
    #expect(responder.shouldEnd(progress(backlog: 0, now: 60_000)))
}

@Test func keepsDuringTheSettleTime() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    responder.activity(atMS: 10_000)
    #expect(!responder.shouldEnd(progress(now: 12_999)))
    #expect(responder.shouldEnd(progress(now: 13_000)))
}

@Test func keepsUntilAckedWhileConnected() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    #expect(!responder.shouldEnd(progress(unacked: 2, connected: true, now: 20_000)))
    #expect(responder.shouldEnd(progress(unacked: 0, connected: true, now: 20_000)))
}

@Test func givesUpOnTheMacAfterFifteenSeconds() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    #expect(!responder.shouldEnd(progress(unacked: 1, connected: false, now: 14_999)))
    #expect(responder.shouldEnd(progress(unacked: 1, connected: false, now: 15_000)))
}

@Test func neverEndsWithoutATask() {
    let responder = WatchWakeResponder()
    #expect(!responder.shouldEnd(progress(remaining: 0, now: 1_000_000)))
    var foreground = WatchWakeResponder()
    _ = foreground.woke(appIsActive: true, atMS: 0)
    #expect(!foreground.shouldEnd(progress(remaining: 0, now: 1_000_000)))
}

@Test func taskEndedAllowsTheNextBegin() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    responder.taskEnded()
    #expect(!responder.holdsTask)
    #expect(responder.woke(appIsActive: false, atMS: 40_000) == .beginTask)
}

@Test func constantsMatchThePlan() {
    #expect(WatchWakeResponder.settleMS == 3_000)
    #expect(WatchWakeResponder.peerGiveUpMS == 15_000)
    #expect(WatchWakeResponder.finishMarginSeconds == 5)
}

// MARK: - 閉じる間に合図が来た時

@Test func afterFinalizeTheSameTaskEndsWhenNothingNewHappened() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    let generation = responder.taskGeneration
    #expect(responder.outcomeAfterFinalize(startedGeneration: generation, progress: progress(now: 20_000)) == .endNow)
}

@Test func aWakeDuringFinalizeKeepsTheMonitorAlive() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    let generation = responder.taskGeneration
    // finishAllの間に次の合図（keepTask）。最後の動きが新しいので、settleの間は終えない
    #expect(responder.woke(appIsActive: false, atMS: 19_000) == .keepTask)
    #expect(
        responder.outcomeAfterFinalize(startedGeneration: generation, progress: progress(now: 20_000))
            == .keepMonitoring)
    #expect(responder.outcomeAfterFinalize(startedGeneration: generation, progress: progress(now: 22_000)) == .endNow)
}

@Test func aNewTaskDuringFinalizeIsNotEndedByTheOldMonitor() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    let generation = responder.taskGeneration
    // 期限切れで終え、次の合図で新しいtaskを取った
    responder.taskEnded()
    #expect(responder.woke(appIsActive: false, atMS: 10_000) == .beginTask)
    #expect(responder.taskGeneration != generation)
    #expect(
        responder.outcomeAfterFinalize(startedGeneration: generation, progress: progress(now: 90_000))
            == .taskReplaced)
}

@Test func aTaskEndedDuringFinalizeIsReportedAsGone() {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    let generation = responder.taskGeneration
    responder.taskEnded()
    #expect(responder.outcomeAfterFinalize(startedGeneration: generation, progress: progress(now: 90_000)) == .taskReplaced)
}

// MARK: - peer

@Test func waitingToRetryConnectsNow() {
    #expect(PeerWakePolicy.onWake(.waitingToRetry) == .connectNow)
}

@Test func staleConnectionReconnects() {
    #expect(PeerWakePolicy.onWake(.connected(lastActivityAgeMS: 75_001)) == .reconnectNow)
    #expect(PeerWakePolicy.onWake(.connected(lastActivityAgeMS: 75_000)) == .none)
}

@Test func freshConnectionIsKept() {
    #expect(PeerWakePolicy.onWake(.connected(lastActivityAgeMS: 1_000)) == .none)
}

@Test func browsingIsLeftAlone() {
    #expect(PeerWakePolicy.onWake(.browsingOrConnecting) == .none)
}

@Test func stoppedDoesNothing() {
    #expect(PeerWakePolicy.onWake(.stopped) == .none)
}

// MARK: - trace

@Test func traceRoundTrips() throws {
    let record = RelayTraceRecord(
        atMS: 1_000, event: .segAcked, appState: "background", remainingSeconds: 22.5, device: "watch-abc",
        session: "100", index: 4, seq: 9, endAtMS: 5_000, detail: "ok")
    let line = try record.encodedLine()
    #expect(!line.contains("\n"))
    #expect(RelayTraceRecord.decodeLines(line + "\n") == [record])
}

@Test func traceOmitsNilFields() throws {
    let line = try RelayTraceRecord(atMS: 1, event: .taskBegan).encodedLine()
    #expect(line == #"{"at_ms":1,"event":"task_began"}"#)
}

@Test func traceSkipsBrokenAndUnknownLines() throws {
    let good = try RelayTraceRecord(atMS: 1, event: .wakeMessage).encodedLine()
    let text = good + "\n{broken\n{\"at_ms\":2,\"event\":\"nope\"}\n\n" + good + "\n"
    #expect(RelayTraceRecord.decodeLines(text).count == 2)
}

@Test func traceKeysAreSnakeCase() throws {
    let line = try RelayTraceRecord(
        atMS: 1, event: .segEnqueued, appState: "active", remainingSeconds: 3, endAtMS: 9
    ).encodedLine()
    #expect(line.contains("\"remaining_s\""))
    #expect(line.contains("\"end_at_ms\""))
    #expect(line.contains("\"app_state\""))
    #expect(line.contains("\"seg_enqueued\""))
}
