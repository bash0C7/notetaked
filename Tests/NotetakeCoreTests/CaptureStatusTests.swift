import Foundation
import Testing
@testable import NotetakeCore

private func actual(
    prefix: String = "p", updated: Int64 = 10_000, mic: CaptureActualState.SourceStatus? = nil,
    system: CaptureActualState.SourceStatus? = nil
) -> CaptureActualState {
    CaptureActualState(pid: 1, prefix: prefix, sources: [mic, system].compactMap { $0 }, updated: updated)
}

@Test func actualWatcherReportsStatusOnlyWhenItChanges() {
    var watcher = CaptureActualWatcher()
    let recording = actual(mic: .init(source: .mic, state: .recording), system: .init(source: .system, state: .recording))

    let first = watcher.observe(recording, prefix: "p", sources: [.mic, .system], nowMS: 10_500)
    #expect(first.snapshot?.statuses == [
        CaptureStatus(source: .mic, state: .recording), CaptureStatus(source: .system, state: .recording),
    ])
    #expect(watcher.observe(recording, prefix: "p", sources: [.mic, .system], nowMS: 11_000).snapshot == nil)

    let retrying = actual(
        updated: 12_000, mic: .init(source: .mic, state: .recording),
        system: .init(source: .system, state: .retrying, reason: "The stream was stopped by the system"))
    let changed = watcher.observe(retrying, prefix: "p", sources: [.mic, .system], nowMS: 12_100)
    #expect(changed.snapshot?.statuses[1] == CaptureStatus(source: .system, state: .retrying, reason: "The stream was stopped by the system"))
}

@Test func actualWatcherSendsInputResetOncePerFallback() {
    var watcher = CaptureActualWatcher()
    let fellBack = actual(mic: .init(source: .mic, state: .recording, fellBackFromPinned: true))
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_000).inputReset)
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_500).inputReset == false)
    let restored = actual(mic: .init(source: .mic, state: .recording, fellBackFromPinned: false))
    #expect(watcher.observe(restored, prefix: "p", sources: [.mic], nowMS: 10_600).inputReset == false)
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_700).inputReset)
}

@Test func actualWatcherCarriesTheErrorInTheSnapshotUntilItClears() {
    var watcher = CaptureActualWatcher()
    let failing = actual(mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_000).snapshot?.statuses
        == [CaptureStatus(source: .mic, state: .recording, lastError: "生音声を書けません")])
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_500).snapshot == nil)
    let cleared = actual(mic: .init(source: .mic, state: .recording))
    #expect(watcher.observe(cleared, prefix: "p", sources: [.mic], nowMS: 11_000).snapshot?.statuses
        == [CaptureStatus(source: .mic, state: .recording)])
}

@Test func captureStatusDecodesWithoutLastError() throws {
    let status = try JSONDecoder().decode(CaptureStatus.self, from: Data(#"{"source":"mic","state":"recording"}"#.utf8))
    #expect(status.lastError == nil)
}

@Test func actualWatcherTreatsStaleOrMissingStateAsUnresponsive() {
    var watcher = CaptureActualWatcher()
    let stale = watcher.observe(actual(updated: 1_000), prefix: "p", sources: [.system], nowMS: 6_001)
    #expect(stale.snapshot?.statuses == [
        CaptureStatus(source: .system, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason)
    ])
    #expect(watcher.observe(nil, prefix: "p", sources: [.system], nowMS: 7_000).snapshot == nil)
}

@Test func actualWatcherIgnoresStateOfAnotherRecording() {
    var watcher = CaptureActualWatcher()
    let other = actual(prefix: "old", mic: .init(source: .mic, state: .recording))
    #expect(watcher.observe(other, prefix: "new", sources: [.mic], nowMS: 10_000) == CaptureActualWatcher.Changes())
}

@Test func beginRecordingKeepsTheFallbackSoItIsNotSentAgain() {
    var watcher = CaptureActualWatcher()
    let fellBack = actual(mic: .init(source: .mic, state: .recording, fellBackFromPinned: true))
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_000).inputReset)

    watcher.beginRecording(keepingSnapshot: true)

    let next = actual(prefix: "q", mic: .init(source: .mic, state: .recording, fellBackFromPinned: true))
    #expect(watcher.observe(next, prefix: "q", sources: [.mic], nowMS: 10_500).inputReset == false)
}

@Test func beginRecordingDecidesWhetherTheFirstSnapshotIsSentAgain() {
    var watcher = CaptureActualWatcher()
    let recording = actual(mic: .init(source: .mic, state: .recording))
    _ = watcher.observe(recording, prefix: "p", sources: [.mic], nowMS: 10_000)

    watcher.beginRecording(keepingSnapshot: true)
    #expect(watcher.observe(recording, prefix: "p", sources: [.mic], nowMS: 10_500).snapshot == nil)

    watcher.beginRecording(keepingSnapshot: false)
    #expect(watcher.observe(recording, prefix: "p", sources: [.mic], nowMS: 11_000).snapshot != nil)
}

@Test func actualWatcherReportsADaemonThatDoesNotSwitchToTheNewRecording() {
    var watcher = CaptureActualWatcher()
    let old = actual(prefix: "old", updated: 10_000, mic: .init(source: .mic, state: .recording))
    let fresh = { (updated: Int64) in
        actual(prefix: "old", updated: updated, mic: .init(source: .mic, state: .recording))
    }
    #expect(watcher.observe(old, prefix: "new", sources: [.mic], nowMS: 10_000).snapshot == nil)
    #expect(watcher.observe(fresh(13_000), prefix: "new", sources: [.mic], nowMS: 13_000).snapshot == nil)

    let stuck = watcher.observe(fresh(15_000), prefix: "new", sources: [.mic], nowMS: 15_000)
    #expect(stuck.snapshot?.statuses == [
        CaptureStatus(source: .mic, state: .retrying, reason: CaptureActualWatcher.notSwitchedReason)
    ])
    #expect(watcher.observe(fresh(16_000), prefix: "new", sources: [.mic], nowMS: 16_000).snapshot == nil)

    let switched = actual(prefix: "new", updated: 17_000, mic: .init(source: .mic, state: .recording))
    #expect(watcher.observe(switched, prefix: "new", sources: [.mic], nowMS: 17_000).snapshot?.statuses == [
        CaptureStatus(source: .mic, state: .recording)
    ])
}

@Test func actualWatcherRestartsTheSwitchTimerForEachRecording() {
    var watcher = CaptureActualWatcher()
    let old = { (updated: Int64) in
        actual(prefix: "old", updated: updated, mic: .init(source: .mic, state: .recording))
    }
    _ = watcher.observe(old(10_000), prefix: "new", sources: [.mic], nowMS: 10_000)

    watcher.beginRecording(keepingSnapshot: true)

    #expect(watcher.observe(old(14_000), prefix: "newer", sources: [.mic], nowMS: 14_000).snapshot == nil)
    #expect(watcher.observe(old(18_000), prefix: "newer", sources: [.mic], nowMS: 18_000).snapshot == nil)
    #expect(watcher.observe(old(19_000), prefix: "newer", sources: [.mic], nowMS: 19_000).snapshot != nil)
}

@Test func actualWatcherKeepsTheErrorWhileTheStateIsUnresponsive() {
    var watcher = CaptureActualWatcher()
    let failing = actual(updated: 10_000, mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    _ = watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_000)

    let stale = watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 16_000)
    #expect(stale.snapshot?.statuses == [
        CaptureStatus(
            source: .mic, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason,
            lastError: "生音声を書けません")
    ])
}

@Test func actualWatcherKeepsTheErrorWhileTheDaemonDoesNotSwitch() {
    var watcher = CaptureActualWatcher()
    let failing = { (updated: Int64) in
        actual(prefix: "old", updated: updated, mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    }
    _ = watcher.observe(failing(10_000), prefix: "old", sources: [.mic], nowMS: 10_000)
    #expect(watcher.observe(failing(11_000), prefix: "new", sources: [.mic], nowMS: 11_000).snapshot == nil)

    let stuck = watcher.observe(failing(16_000), prefix: "new", sources: [.mic], nowMS: 16_000)
    #expect(stuck.snapshot?.statuses == [
        CaptureStatus(
            source: .mic, state: .retrying, reason: CaptureActualWatcher.notSwitchedReason,
            lastError: "生音声を書けません")
    ])
}

private func noticed(
    _ notice: String, atMS: Int64, updated: Int64, prefix: String = "p", source: Source = .mic
) -> CaptureActualState {
    actual(prefix: prefix, updated: updated, mic: .init(source: source, state: .recording, notice: notice, noticeAtMS: atMS))
}

@Test func actualWatcherEmitsEachNoticeOnceWhenItsTimeIsNewer() {
    var watcher = CaptureActualWatcher(startedAtMS: 1_000)
    let first = watcher.observe(
        noticed("最後の音声を書けません: x", atMS: 10_000, updated: 10_000), prefix: "p", sources: [.mic], nowMS: 10_000)
    #expect(first.notices == ["mic: 最後の音声を書けません: x"])
    // 同じ実状態を読み直しても、同じ通知を重ねて伝えない
    #expect(watcher.observe(
        noticed("最後の音声を書けません: x", atMS: 10_000, updated: 11_000), prefix: "p", sources: [.mic], nowMS: 11_000
    ).notices.isEmpty)
    #expect(watcher.observe(
        noticed("最後の音声を書けません: x", atMS: 12_000, updated: 12_000), prefix: "p", sources: [.mic], nowMS: 12_000
    ).notices == ["mic: 最後の音声を書けません: x"])
}

@Test func actualWatcherEmitsANoticeFromARecreatedRecorderAfterAnEarlierOne() {
    var watcher = CaptureActualWatcher(startedAtMS: 1_000)
    _ = watcher.observe(noticed("a", atMS: 50_000, updated: 50_000), prefix: "p", sources: [.mic], nowMS: 50_000)
    _ = watcher.observe(noticed("b", atMS: 60_000, updated: 60_000), prefix: "p", sources: [.mic], nowMS: 60_000)

    // 録り直しなどでrecorderが作り直されても、通知の時刻は進み続けるので落とさない
    let recreated = watcher.observe(
        noticed("c", atMS: 70_000, updated: 70_000, prefix: "q"), prefix: "q", sources: [.mic], nowMS: 70_000)
    #expect(recreated.notices == ["mic: c"])
}

@Test func actualWatcherDoesNotReplayANoticeOlderThanItsStart() {
    var watcher = CaptureActualWatcher(startedAtMS: 20_000)
    let old = noticed("a", atMS: 19_000, updated: 20_500)
    #expect(watcher.observe(old, prefix: "p", sources: [.mic], nowMS: 20_500).notices.isEmpty)
    let fresh = noticed("b", atMS: 21_000, updated: 21_000)
    #expect(watcher.observe(fresh, prefix: "p", sources: [.mic], nowMS: 21_000).notices == ["mic: b"])
}

@Test func actualWatcherKeepsTheSeenNoticePerSourceAcrossRecordings() {
    var watcher = CaptureActualWatcher(startedAtMS: 1_000)
    let state = { (prefix: String, updated: Int64) in
        actual(
            prefix: prefix, updated: updated,
            mic: .init(source: .mic, state: .recording, notice: "a", noticeAtMS: 5_000),
            system: .init(source: .system, state: .recording, notice: "b", noticeAtMS: 6_000))
    }
    #expect(watcher.observe(state("p", 10_000), prefix: "p", sources: [.mic, .system], nowMS: 10_000).notices
        == ["mic: a", "system: b"])

    watcher.beginRecording(keepingSnapshot: false)

    // 前の収録で伝えた通知は、実状態に残っていても繰り返さない
    #expect(watcher.observe(state("q", 11_000), prefix: "q", sources: [.mic, .system], nowMS: 11_000).notices.isEmpty)
}

@Test func actualWatcherDoesNotEmitNoticesOfAnotherRecordingOrAStaleState() {
    var watcher = CaptureActualWatcher(startedAtMS: 1_000)
    let other = noticed("a", atMS: 10_000, updated: 10_000, prefix: "old")
    #expect(watcher.observe(other, prefix: "new", sources: [.mic], nowMS: 10_000).notices.isEmpty)
    #expect(watcher.observe(other, prefix: "new", sources: [.mic], nowMS: 20_000).notices.isEmpty)
}

@Test func noticeDoesNotChangeTheStatusSnapshot() {
    var watcher = CaptureActualWatcher(startedAtMS: 1_000)
    let plain = actual(mic: .init(source: .mic, state: .recording))
    _ = watcher.observe(plain, prefix: "p", sources: [.mic], nowMS: 10_000)
    let changes = watcher.observe(
        noticed("a", atMS: 10_400, updated: 10_500), prefix: "p", sources: [.mic], nowMS: 10_500)
    #expect(changes.snapshot == nil)
    #expect(changes.notices == ["mic: a"])
}
