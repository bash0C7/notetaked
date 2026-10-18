import Foundation
import Testing
@testable import NotetakeCore

@Test func unreachableIsSkipped() {
    var gate = WatchWakeGate()
    let result = gate.decide(isReachable: false, nowMS: 0)
    #expect(result.decision == .skipUnreachable)
    #expect(result.note == .none)
}

@Test func firstChunkIsSent() {
    var gate = WatchWakeGate()
    let result = gate.decide(isReachable: true, nowMS: 0)
    #expect(result.decision == .send(attempt: 1))
    #expect(result.note == .none)
}

@Test func waitingForAReplySkips() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    #expect(gate.decide(isReachable: true, nowMS: 15_000).decision == .skipInFlight)
}

@Test func tooSoonIsSkipped() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    _ = gate.replied(attempt: 1, atMS: 100)
    #expect(gate.decide(isReachable: true, nowMS: 9_999).decision == .skipTooSoon)
    #expect(gate.decide(isReachable: true, nowMS: 10_000).decision == .send(attempt: 2))
}

@Test func replyClearsInFlight() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    #expect(gate.replied(attempt: 1, atMS: 500) == .none)
    #expect(gate.decide(isReachable: true, nowMS: 20_000).decision == .send(attempt: 2))
}

@Test func timeoutCountsAsAFailureAndAllowsTheNext() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    let result = gate.decide(isReachable: true, nowMS: 30_000)
    #expect(result.note == .firstFailure(detail: "reply timeout"))
    #expect(result.decision == .send(attempt: 2))
    #expect(gate.consecutiveFailures == 1)
}

@Test func onlyTheFirstFailureOfAStreakIsNoted() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    #expect(gate.failed(attempt: 1, atMS: 100, detail: "x") == .firstFailure(detail: "x"))
    _ = gate.decide(isReachable: true, nowMS: 10_000)
    #expect(gate.failed(attempt: 2, atMS: 10_100, detail: "x") == .none)
    _ = gate.decide(isReachable: true, nowMS: 20_000)
    #expect(gate.failed(attempt: 3, atMS: 20_100, detail: "x") == .none)
    #expect(gate.consecutiveFailures == 3)
}

@Test func replyAfterFailuresNotesRecovery() {
    var gate = WatchWakeGate()
    for i in 0..<3 {
        let nowMS = Int64(i) * 10_000
        let attempt = i + 1
        _ = gate.decide(isReachable: true, nowMS: nowMS)
        _ = gate.failed(attempt: attempt, atMS: nowMS + 100, detail: "x")
    }
    _ = gate.decide(isReachable: true, nowMS: 30_000)
    #expect(gate.replied(attempt: 4, atMS: 30_100) == .recovered(failures: 3))
    #expect(gate.consecutiveFailures == 0)
    _ = gate.decide(isReachable: true, nowMS: 40_000)
    #expect(gate.failed(attempt: 5, atMS: 40_100, detail: "y") == .firstFailure(detail: "y"))
}

@Test func lateErrorOfATimedOutAttemptIsNotCountedTwice() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    _ = gate.decide(isReachable: true, nowMS: 30_000)
    #expect(gate.consecutiveFailures == 1)
    #expect(gate.failed(attempt: 1, atMS: 31_000, detail: "late") == .none)
    #expect(gate.consecutiveFailures == 1)
}

@Test func lateReplyOfATimedOutAttemptStillRecovers() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    _ = gate.decide(isReachable: true, nowMS: 30_000)
    #expect(gate.replied(attempt: 1, atMS: 31_000) == .recovered(failures: 1))
    #expect(gate.consecutiveFailures == 0)
}

@Test func unreachableDoesNotCountAsAFailure() {
    var gate = WatchWakeGate()
    for i in 0..<5 {
        _ = gate.decide(isReachable: false, nowMS: Int64(i) * 10_000)
    }
    #expect(gate.consecutiveFailures == 0)
}

@Test func finalIgnoresTheMinimumInterval() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    _ = gate.replied(attempt: 1, atMS: 100)
    #expect(gate.decide(isReachable: true, nowMS: 3_000).decision == .skipTooSoon)
    #expect(gate.decideFinal(isReachable: true, nowMS: 3_000).decision == .send(attempt: 2))
}

@Test func finalIsSentEvenWhileAnEarlierWakeIsInFlight() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    #expect(gate.decideFinal(isReachable: true, nowMS: 3_000).decision == .send(attempt: 2))
    // 古い合図のerrorは二重に数えず、新しい合図の返事待ちを解かない
    #expect(gate.failed(attempt: 1, atMS: 3_500, detail: "old") == .none)
    #expect(gate.replied(attempt: 2, atMS: 3_600) == .none)
}

@Test func finalIsSentWhenNoWakeWasSentBefore() {
    var gate = WatchWakeGate()
    #expect(gate.decideFinal(isReachable: true, nowMS: 500).decision == .send(attempt: 1))
}

@Test func finalIsSkippedWhenUnreachable() {
    var gate = WatchWakeGate()
    #expect(gate.decideFinal(isReachable: false, nowMS: 500).decision == .skipUnreachable)
}

@Test func finalStillCountsATimedOutWake() {
    var gate = WatchWakeGate()
    _ = gate.decide(isReachable: true, nowMS: 0)
    let result = gate.decideFinal(isReachable: true, nowMS: 30_000)
    #expect(result.note == .firstFailure(detail: "reply timeout"))
    #expect(result.decision == .send(attempt: 2))
}

@Test func finalAfterFinalIsAlsoSent() {
    var gate = WatchWakeGate()
    _ = gate.decideFinal(isReachable: true, nowMS: 0)
    #expect(gate.decideFinal(isReachable: true, nowMS: 1_000).decision == .send(attempt: 2))
}
