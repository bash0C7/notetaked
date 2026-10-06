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

@Test func actualWatcherReportsEachNewErrorOnce() {
    var watcher = CaptureActualWatcher()
    let failing = actual(mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_000).errors == ["mic: 生音声を書けません"])
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_500).errors == [])
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

@Test func beginRecordingForgetsReportedErrors() {
    var watcher = CaptureActualWatcher()
    let failing = actual(mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_000).errors == ["mic: 生音声を書けません"])

    watcher.beginRecording(keepingSnapshot: true)

    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_500).errors == ["mic: 生音声を書けません"])
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
