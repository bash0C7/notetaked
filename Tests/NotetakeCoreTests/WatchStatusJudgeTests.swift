import Testing
@testable import NotetakeCore

private let now: Int64 = 10_000_000

private func snap(
    state: WatchRecordingState, reason: WatchHaltReason? = nil, stateAt: Int64? = nil,
    lastChunk: Int64? = nil, pending: Int = 0, battery: Double? = nil
) -> WatchStatusSnapshot {
    WatchStatusSnapshot(
        device: "d", deviceName: "n", state: state, haltReason: reason, stateAtMS: stateAt,
        lastChunkReceivedAtMS: lastChunk, batteryLevel: battery, inboxPendingCount: pending,
        updatedAtMS: now)
}

@Test func nilSnapshotIsNormalAndEmpty() {
    #expect(WatchStatusJudge.judge(nil, nowMS: now) == IndicatorMessage(severity: .normal, text: ""))
}

@Test func haltedIsAnAlertWithTheReason() {
    let m = WatchStatusJudge.judge(snap(state: .halted, reason: .interrupted), nowMS: now)
    #expect(m == IndicatorMessage(severity: .alert, text: "Watchが止まりました: 割り込み（通話・Siriなど）"))
}

@Test func haltedWithoutReasonHasNoColon() {
    let m = WatchStatusJudge.judge(snap(state: .halted), nowMS: now)
    #expect(m == IndicatorMessage(severity: .alert, text: "Watchが止まりました"))
}

@Test func haltedWinsOverEverythingElse() {
    let m = WatchStatusJudge.judge(
        snap(state: .halted, reason: .noAudio, lastChunk: now - 600_000, pending: 3, battery: 0.05), nowMS: now)
    #expect(m.severity == .alert)
}

@Test func recordingWithoutChunksForThreeMinutesIsACaution() {
    let at = snap(state: .recording, lastChunk: now - 180_000)
    #expect(WatchStatusJudge.judge(at, nowMS: now) == IndicatorMessage(severity: .caution, text: "Watchから届いていません（3分）"))
    let under = snap(state: .recording, lastChunk: now - 179_999)
    #expect(WatchStatusJudge.judge(under, nowMS: now).severity != .caution)
}

@Test func recordingWithNoChunkYetCountsFromTheStart() {
    let m = WatchStatusJudge.judge(snap(state: .recording, stateAt: now - 180_000), nowMS: now)
    #expect(m == IndicatorMessage(severity: .caution, text: "Watchから届いていません（3分）"))
}

@Test func staleWinsOverPendingAndBattery() {
    let m = WatchStatusJudge.judge(
        snap(state: .recording, lastChunk: now - 240_000, pending: 2, battery: 0.1), nowMS: now)
    #expect(m == IndicatorMessage(severity: .caution, text: "Watchから届いていません（4分）"))
}

@Test func pendingInboxIsInfo() {
    let m = WatchStatusJudge.judge(snap(state: .recording, lastChunk: now - 1000, pending: 2), nowMS: now)
    #expect(m == IndicatorMessage(severity: .info, text: "未処理2件（iPhoneを開くと文字起こし）"))
}

@Test func pendingAfterStopIsStillInfo() {
    let m = WatchStatusJudge.judge(snap(state: .stopped, pending: 1), nowMS: now)
    #expect(m.severity == .info)
}

@Test func lowBatteryWhileRecordingIsACaution() {
    let low = WatchStatusJudge.judge(snap(state: .recording, lastChunk: now, battery: 0.19), nowMS: now)
    #expect(low == IndicatorMessage(severity: .caution, text: "Watchの電池が少ない（19%）"))
    let ok = WatchStatusJudge.judge(snap(state: .recording, lastChunk: now, battery: 0.2), nowMS: now)
    #expect(ok == IndicatorMessage(severity: .normal, text: "Watch録音中"))
}

@Test func lowBatteryWhileStoppedIsEmpty() {
    let m = WatchStatusJudge.judge(snap(state: .stopped, battery: 0.05), nowMS: now)
    #expect(m == IndicatorMessage(severity: .normal, text: ""))
}

@Test func recordingIsNormal() {
    let m = WatchStatusJudge.judge(snap(state: .recording, lastChunk: now - 1000), nowMS: now)
    #expect(m == IndicatorMessage(severity: .normal, text: "Watch録音中"))
}

@Test func stoppedIsEmpty() {
    #expect(WatchStatusJudge.judge(snap(state: .stopped), nowMS: now) == IndicatorMessage(severity: .normal, text: ""))
}

@Test func unknownIsEmpty() {
    #expect(WatchStatusJudge.judge(snap(state: .unknown), nowMS: now) == IndicatorMessage(severity: .normal, text: ""))
}
