import Foundation
import Testing
@testable import NotetakeCore

private let device = "watch-abc"

private func receipt(
    session: String = "1000000", index: Int, startAtMS: Int64? = nil, durationMS: Int64? = 20_000,
    maxDBFS: Double? = -20, battery: Double? = nil, isFinal: Bool? = nil, receivedAtMS: Int64? = nil
) -> WatchChunkReceipt {
    let start = startAtMS ?? (Int64(session) ?? 0) + Int64(index) * 20_000
    return WatchChunkReceipt(
        metadata: WatchChunkMetadata(
            session: session, index: index, startAtMS: start, sampleRate: 16000, device: device,
            deviceName: "Watch", owner: "小芝", maxDBFS: maxDBFS, meanDBFS: maxDBFS.map { $0 - 10 },
            batteryLevel: battery, durationMS: durationMS, isFinal: isFinal),
        receivedAtMS: receivedAtMS ?? (start + 25_000))
}

private func obs(
    _ event: WatchObsEvent, at: Int64, session: String? = "1000000", reason: WatchHaltReason? = nil,
    detail: String? = nil, battery: Double? = nil
) -> WatchObsRecord {
    WatchObsRecord(atMS: at, event: event, session: session, detail: detail, batteryLevel: battery, haltReason: reason)
}

@Test func firstChunkStartsRecording() {
    var tracker = WatchStatusTracker()
    #expect(tracker.snapshot == nil)
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    let snapshot = tracker.snapshot
    #expect(snapshot?.device == device)
    #expect(snapshot?.deviceName == "Watch")
    #expect(snapshot?.session == "1000000")
    #expect(snapshot?.state == .recording)
    #expect(snapshot?.lastChunkIndex == 0)
    #expect(snapshot?.lastChunkReceivedAtMS == Int64(1_025_000))
    #expect(snapshot?.levels.count == 1)
}

@Test func finalChunkStops() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.chunkReceived(receipt(index: 1, isFinal: true), deviceName: "Watch")
    #expect(tracker.snapshot?.state == .stopped)
}

@Test func newSessionResetsLevelsAndGaps() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.chunkReceived(receipt(index: 3), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 2_000_000, reason: .noAudio, detail: "x")])
    #expect(tracker.snapshot?.missingChunkCount == 2)
    tracker.chunkReceived(receipt(session: "5000000", index: 0), deviceName: "Watch")
    let snapshot = tracker.snapshot
    #expect(snapshot?.session == "5000000")
    #expect(snapshot?.levels.count == 1)
    #expect(snapshot?.missingChunkCount == 0)
    #expect(snapshot?.state == .recording)
    #expect(snapshot?.haltReason == nil)
    #expect(snapshot?.haltDetail == nil)
}

@Test func olderSessionChunkDoesNotReplaceTheCurrent() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(session: "5000000", index: 0), deviceName: "Watch")
    let before = tracker.snapshot
    tracker.chunkReceived(receipt(session: "1000000", index: 7, receivedAtMS: 9_999_999), deviceName: "Watch")
    let after = tracker.snapshot
    #expect(after?.session == "5000000")
    #expect(after?.levels == before?.levels)
    #expect(after?.state == before?.state)
    #expect(after?.lastChunkIndex == 0)
    #expect(after?.missingChunkCount == 0)
    #expect(after?.lastChunkReceivedAtMS == 9_999_999)
}

@Test func lateChunkDoesNotUndoAHalt() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 3, startAtMS: 120_000), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 200_000, reason: .interrupted)])
    #expect(tracker.snapshot?.state == .halted)
    tracker.chunkReceived(receipt(index: 2, startAtMS: 60_000), deviceName: "Watch")
    #expect(tracker.snapshot?.state == .halted)
    #expect(tracker.snapshot?.haltReason == .interrupted)
}

@Test func laterChunkAfterAHaltResumesRecording() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 1_030_000, reason: .interrupted)])
    tracker.chunkReceived(receipt(index: 5), deviceName: "Watch")
    #expect(tracker.snapshot?.state == .recording)
    #expect(tracker.snapshot?.haltReason == nil)
}

@Test func levelsKeepTheNewestNinety() {
    var tracker = WatchStatusTracker()
    for index in 0..<100 { tracker.chunkReceived(receipt(index: index), deviceName: "Watch") }
    let levels = tracker.snapshot?.levels ?? []
    #expect(levels.count == WatchStatusSnapshot.maxLevels)
    #expect(levels.first?.index == 99)
    #expect(levels.last?.index == 10)
    #expect(levels.first?.maxDBFS == -20)
}

@Test func skippedIndexesCountAsMissing() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.chunkReceived(receipt(index: 3), deviceName: "Watch")
    #expect(tracker.snapshot?.missingChunkCount == 2)
    #expect(tracker.snapshot?.lastChunkIndex == 3)
}

@Test func lateIndexIsNoLongerMissing() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.chunkReceived(receipt(index: 2), deviceName: "Watch")
    #expect(tracker.snapshot?.missingChunkCount == 1)
    tracker.chunkReceived(receipt(index: 1), deviceName: "Watch")
    #expect(tracker.snapshot?.missingChunkCount == 0)
    #expect(tracker.snapshot?.lastChunkIndex == 2)
}

@Test func haltedRecordSetsTheReason() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 1_100_000, reason: .routeChanged, detail: "AirPods")])
    let snapshot = tracker.snapshot
    #expect(snapshot?.state == .halted)
    #expect(snapshot?.haltReason == .routeChanged)
    #expect(snapshot?.haltDetail == "AirPods")
    #expect(snapshot?.stateAtMS == 1_100_000)
}

@Test func autoStoppedRecordStopsWithItsReason() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.autoStopped, at: 1_100_000, reason: .autoStopped)])
    #expect(tracker.snapshot?.state == .stopped)
    #expect(tracker.snapshot?.haltReason == .autoStopped)
}

@Test func stoppedRecordStops() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.stopped, at: 1_100_000)])
    #expect(tracker.snapshot?.state == .stopped)
    #expect(tracker.snapshot?.haltReason == nil)
}

@Test func startedRecordClearsTheHaltReason() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 1_100_000, reason: .noAudio, detail: "d")])
    tracker.obsReceived([obs(.started, at: 1_200_000)])
    let snapshot = tracker.snapshot
    #expect(snapshot?.state == .recording)
    #expect(snapshot?.haltReason == nil)
    #expect(snapshot?.haltDetail == nil)
}

@Test func olderRecordDoesNotOverrideNewerState() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 1_200_000, reason: .noAudio)])
    tracker.obsReceived([obs(.started, at: 1_100_000)])
    #expect(tracker.snapshot?.state == .halted)
}

@Test func olderSessionRecordIsIgnored() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(session: "5000000", index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 9_000_000, session: "1000000", reason: .noAudio)])
    #expect(tracker.snapshot?.state == .recording)
    #expect(tracker.snapshot?.session == "5000000")
}

@Test func recordsBeforeAnyChunkAreIgnoredWithoutIdentity() {
    var tracker = WatchStatusTracker()
    tracker.obsReceived([obs(.halted, at: 10, reason: .startFailed)])
    #expect(tracker.snapshot == nil)
}

@Test func recordsCanCreateTheSnapshotWhenTheDeviceIsGiven() {
    var tracker = WatchStatusTracker()
    tracker.obsReceived([obs(.halted, at: 10, reason: .startFailed)], device: device, deviceName: "Watch")
    #expect(tracker.snapshot?.state == .halted)
    #expect(tracker.snapshot?.haltReason == .startFailed)
    #expect(tracker.snapshot?.device == device)
}

@Test func batteryComesFromChunkOrObs() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0, battery: 0.9), deviceName: "Watch")
    #expect(tracker.snapshot?.batteryLevel == 0.9)
    tracker.obsReceived([obs(.chunkClosed, at: 1_100_000, battery: 0.5)])
    #expect(tracker.snapshot?.batteryLevel == 0.5)
    tracker.obsReceived([obs(.chunkClosed, at: 1_050_000, battery: 0.7)])
    #expect(tracker.snapshot?.batteryLevel == 0.5)
    tracker.chunkReceived(receipt(index: 9, battery: 0.3), deviceName: "Watch")
    #expect(tracker.snapshot?.batteryLevel == 0.3)
}

@Test func textAndInboxAreReflected() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.textEmitted("こんにちは", atMS: 1_040_000)
    tracker.inboxChanged(pendingCount: 4, atMS: 1_050_000)
    let snapshot = tracker.snapshot
    #expect(snapshot?.lastText == "こんにちは")
    #expect(snapshot?.lastTextAtMS == 1_040_000)
    #expect(snapshot?.inboxPendingCount == 4)
    #expect(snapshot?.updatedAtMS == 1_050_000)
}

@Test func restoredSnapshotKeepsTheOldState() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    let restored = WatchStatusTracker(snapshot: tracker.snapshot)
    #expect(restored.snapshot == tracker.snapshot)
}

// MARK: - review修正

@Test func finalChunkClosedAfterAHaltDoesNotUndoIt() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 1_030_000, reason: .interrupted, detail: "call")])
    // Watchはhaltを記録した後に最後の小片を閉じる。その終わりはhaltの時刻以後になる
    tracker.chunkReceived(receipt(index: 1, startAtMS: 1_010_000, durationMS: 40_000, isFinal: true), deviceName: "Watch")
    #expect(tracker.snapshot?.state == .halted)
    #expect(tracker.snapshot?.haltReason == .interrupted)
    #expect(tracker.snapshot?.haltDetail == "call")
}

@Test func haltedRecordAfterTheFinalChunkStillApplies() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.chunkReceived(receipt(index: 1, startAtMS: 1_010_000, durationMS: 40_000, isFinal: true), deviceName: "Watch")
    #expect(tracker.snapshot?.state == .stopped)
    tracker.obsReceived([obs(.halted, at: 1_030_000, reason: .noAudio)])
    #expect(tracker.snapshot?.state == .halted)
    #expect(tracker.snapshot?.haltReason == .noAudio)
}

@Test func startFailedRecordShowsAsAHalt() {
    var tracker = WatchStatusTracker()
    tracker.obsReceived([obs(.startFailed, at: 10, detail: "mic busy")], device: device, deviceName: "Watch")
    #expect(tracker.snapshot?.state == .halted)
    #expect(tracker.snapshot?.haltReason == .startFailed)
    #expect(tracker.snapshot?.haltDetail == "mic busy")
}

@Test func recordsFromAnotherDeviceReplaceTheSnapshot() {
    var tracker = WatchStatusTracker()
    tracker.chunkReceived(receipt(index: 0), deviceName: "Watch")
    tracker.obsReceived([obs(.halted, at: 10, reason: .noAudio)], device: "watch-other", deviceName: "Other")
    #expect(tracker.snapshot?.device == "watch-other")
    #expect(tracker.snapshot?.deviceName == "Other")
}
