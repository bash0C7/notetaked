import Foundation
import Testing
@testable import NotetakeCore

private func progress(
    backlog: Int = 0, unacked: Int = 0, connected: Bool = true, connecting: Bool = false,
    remaining: Double = 25, now: Int64
) -> WatchWakeResponder.Progress {
    .init(
        intakeBacklog: backlog, unackedSegments: unacked, peerConnected: connected, remainingSeconds: remaining,
        nowMS: now, peerConnecting: connecting)
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

@Test func youngBrowsingIsLeftAlone() {
    #expect(PeerWakePolicy.onWake(.attempting(ageMS: 2_000, crossedSuspend: false)) == .none)
    #expect(PeerWakePolicy.onWake(.attempting(ageMS: 5_000, crossedSuspend: false)) == .none)
}

@Test func longBrowsingOrConnectingIsRestarted() {
    #expect(PeerWakePolicy.onWake(.attempting(ageMS: 10_000, crossedSuspend: false)) == .reconnectNow)
    #expect(PeerWakePolicy.onWake(.attempting(ageMS: 5_001, crossedSuspend: false)) == .reconnectNow)
}

@Test func attemptThatCrossedSuspendIsRestarted() {
    #expect(PeerWakePolicy.onWake(.attempting(ageMS: 100, crossedSuspend: true)) == .reconnectNow)
}

@Test func connectingKeepsTaskUntilItsOwnLimit() {
    // 15秒を過ぎても、つなぎ中なら20秒まで終えない
    #expect(!responderWoken().shouldEnd(progress(unacked: 1, connected: false, connecting: true, remaining: 14, now: 19_999)))
    #expect(responderWoken().shouldEnd(progress(unacked: 1, connected: false, connecting: true, remaining: 14, now: 20_000)))
    // つなぎ中でなければ従来どおり15秒で諦める
    #expect(responderWoken().shouldEnd(progress(unacked: 1, connected: false, connecting: false, remaining: 14, now: 20_000)))
}

@Test func connectingHoldStopsWhileStreamsCanStillBeFinished() {
    // 保持を打ち切る残りの閾値は、1秒刻みの監視を挟んでも、まだ`finishAll`できる残りより大きい
    #expect(
        WatchWakeResponder.connectingHoldMinRemainingSeconds - 1
            > WatchWakeResponder.finishStreamsMinRemainingSeconds)
    let threshold = WatchWakeResponder.connectingHoldMinRemainingSeconds
    // 閾値を超える間は保持、閾値以下になった監視で終える（その時点の残りは閾値の1秒下まで）
    #expect(!responderWoken().shouldEnd(progress(unacked: 1, connected: false, connecting: true, remaining: threshold + 0.5, now: 16_000)))
    #expect(responderWoken().shouldEnd(progress(unacked: 1, connected: false, connecting: true, remaining: threshold, now: 16_000)))
    #expect(!responderWoken().shouldEnd(progress(unacked: 1, connected: false, connecting: true, remaining: threshold, now: 14_000)))
}

private func responderWoken() -> WatchWakeResponder {
    var responder = WatchWakeResponder()
    _ = responder.woke(appIsActive: false, atMS: 0)
    return responder
}

@Test func stoppedDoesNothing() {
    #expect(PeerWakePolicy.onWake(.stopped) == .none)
}

// MARK: - 逐次の再接続

@Test func reconnectGoesDirectThenBrowse() {
    var r = PeerReconnect()
    r.endpointSaved()
    #expect(r.start(allowDirect: true) == .connectDirect)
    #expect(r.phase == .direct)
    #expect(r.directFailed() == .startBrowse)
    #expect(r.phase == .browsing)
    #expect(!r.hasSavedEndpoint)
    #expect(r.browseFound() == .connectBrowsed)
    #expect(r.browseFound() == .ignore)
    r.ready()
    #expect(r.phase == .connected)
}

@Test func reconnectWithoutSavedEndpointBrowses() {
    var r = PeerReconnect()
    #expect(r.start(allowDirect: true) == .startBrowse)
    #expect(r.start(allowDirect: false) == .startBrowse)
}

@Test func directFailureCallbacksAreIgnoredOutsideDirect() {
    var r = PeerReconnect()
    r.endpointSaved()
    _ = r.start(allowDirect: false)
    #expect(r.directFailed() == .ignore)
    #expect(r.phase == .browsing)
    #expect(r.hasSavedEndpoint)
}

@Test func browseResultDuringDirectIsIgnored() {
    var r = PeerReconnect()
    r.endpointSaved()
    _ = r.start(allowDirect: true)
    #expect(r.browseFound() == .ignore)
    #expect(r.phase == .direct)
}

@Test func wakeDuringBrowseRestartsSequence() {
    var r = PeerReconnect()
    r.endpointSaved()
    _ = r.start(allowDirect: true)
    _ = r.directFailed()
    // 保存した端点は捨てたので、browse中のwakeはbrowseからやり直す
    #expect(r.start(allowDirect: true) == .startBrowse)
    #expect(r.phase == .browsing)
}

@Test func connectionFailureWhileDirectFallsToBrowseNotBackoff() {
    var r = PeerReconnect()
    r.endpointSaved()
    _ = r.start(allowDirect: true)
    #expect(r.connectionFailed() == .startBrowse)
}

@Test func connectionFailureAfterBrowseOrReadyBacksOff() {
    var r = PeerReconnect()
    _ = r.start(allowDirect: true)
    _ = r.browseFound()
    #expect(r.connectionFailed() == .scheduleBackoff)
    #expect(r.phase == .idle)
    #expect(r.connectionFailed() == .ignore)
    _ = r.start(allowDirect: false)
    _ = r.browseFound()
    r.ready()
    #expect(r.connectionFailed() == .scheduleBackoff)
}

@Test func stopIdlesTheSequence() {
    var r = PeerReconnect()
    _ = r.start(allowDirect: false)
    r.stop()
    #expect(r.phase == .idle)
    #expect(r.browseFound() == .ignore)
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

@Test func peerTraceEventsHaveStableNames() throws {
    let cases: [(RelayTraceEvent, String)] = [
        (.peerState, "peer_state"), (.wakeDecision, "wake_decision"), (.browseResult, "browse_result"),
        (.connectStarted, "connect_started"), (.connectReady, "connect_ready"),
    ]
    for (event, name) in cases {
        #expect(try RelayTraceRecord(atMS: 1, event: event).encodedLine() == "{\"at_ms\":1,\"event\":\"\(name)\"}")
    }
}

@Test func peerTraceDetailsAreFixed() {
    #expect(RelayTraceRecord.peerStateDetail(from: "browsing", to: "failed", reason: "timeout") == "browsing->failed reason=timeout")
    #expect(RelayTraceRecord.peerStateDetail(from: "idle", to: "browsing", reason: nil) == "idle->browsing")
    #expect(
        RelayTraceRecord.wakeDecisionDetail(.attempting(ageMS: 7_000, crossedSuspend: true), .reconnectNow)
            == "link=attempting age_ms=7000 crossed_suspend=true decision=reconnectNow")
    #expect(
        RelayTraceRecord.wakeDecisionDetail(.connected(lastActivityAgeMS: 10), PeerWakePolicy.Decision.none)
            == "link=connected age_ms=10 decision=none")
    #expect(RelayTraceRecord.wakeDecisionDetail(.waitingToRetry, .connectNow) == "link=waitingToRetry decision=connectNow")
    #expect(RelayTraceRecord.wakeDecisionDetail(.stopped, .none) == "link=stopped decision=none")
    #expect(RelayTraceRecord.browseResultDetail(count: 2, chosen: "svc") == "count=2 chosen=svc")
    #expect(RelayTraceRecord.connectStartedDetail(endpoint: "e", kind: "direct") == "endpoint=e kind=direct")
    #expect(RelayTraceRecord.connectReadyDetail(elapsedMS: 1200, interface: "en0", kind: "browse") == "elapsed_ms=1200 interface=en0 kind=browse")
    #expect(RelayTraceRecord.connectReadyDetail(elapsedMS: 5, interface: nil, kind: "direct") == "elapsed_ms=5 interface=none kind=direct")
}

// MARK: - 終える前の未送信status

private func statusSnapshot(pending: Int, updatedAtMS: Int64 = 0) -> WatchStatusSnapshot {
    var snapshot = WatchStatusSnapshot(device: "w", deviceName: "Watch", state: .recording, updatedAtMS: updatedAtMS)
    snapshot.inboxPendingCount = pending
    return snapshot
}

@Test func unsentChangedStatusIsFlushedBeforeEnding() {
    let last = statusSnapshot(pending: 1, updatedAtMS: 100)
    let current = statusSnapshot(pending: 0, updatedAtMS: 200)
    #expect(WatchWakeResponder.shouldFlushStatus(current: current, lastSent: last, peerConnected: true))
}

@Test func neverSentStatusIsFlushedBeforeEnding() {
    #expect(WatchWakeResponder.shouldFlushStatus(current: statusSnapshot(pending: 0), lastSent: nil, peerConnected: true))
}

@Test func statusDifferingOnlyInUpdatedAtIsNotFlushed() {
    let last = statusSnapshot(pending: 1, updatedAtMS: 100)
    let current = statusSnapshot(pending: 1, updatedAtMS: 900)
    #expect(!WatchWakeResponder.shouldFlushStatus(current: current, lastSent: last, peerConnected: true))
}

@Test func statusIsNotFlushedWithoutPeerOrWithoutStatus() {
    let current = statusSnapshot(pending: 0)
    #expect(!WatchWakeResponder.shouldFlushStatus(current: current, lastSent: nil, peerConnected: false))
    #expect(!WatchWakeResponder.shouldFlushStatus(current: nil, lastSent: nil, peerConnected: true))
}
