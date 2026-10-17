import Foundation
import Testing
@testable import NotetakeCore

private typealias Reducer = WatchRecordingReducer

@Test func startFromIdleRecords() {
    let phase = Reducer.reduce(.idle, .started(atMS: 100))
    #expect(phase == .recording(startedAtMS: 100, lastBufferAtMS: nil))
    let display = Reducer.display(phase, nowMS: 100)
    #expect(display.isActive)
    #expect(display.message.text == "録音中")
}

@Test func bufferUpdatesTheLastBufferTime() {
    let phase = Reducer.reduce(.recording(startedAtMS: 100, lastBufferAtMS: nil), .bufferArrived(atMS: 900))
    #expect(phase == .recording(startedAtMS: 100, lastBufferAtMS: 900))
}

@Test func interruptionHaltsAndShowsNotRecording() {
    let phase = Reducer.reduce(.recording(startedAtMS: 0, lastBufferAtMS: 1_000), .interruptionBegan(atMS: 2_000))
    #expect(phase == .halted(reason: .interrupted, atMS: 2_000, detail: nil))
    let display = Reducer.display(phase, nowMS: 2_000)
    #expect(display.isActive == false)
    #expect(display.message.severity == .alert)
    #expect(display.message.text.hasPrefix("止まりました"))
}

@Test func interruptionEndedWithShouldResumeDoesNotResume() {
    let halted = WatchRecordingPhase.halted(reason: .interrupted, atMS: 2_000, detail: nil)
    #expect(Reducer.reduce(halted, .interruptionEnded(atMS: 3_000, shouldResume: true)) == halted)
}

@Test func lateBufferDoesNotReviveAHaltedRecording() {
    let halted = WatchRecordingPhase.halted(reason: .interrupted, atMS: 2_000, detail: nil)
    #expect(Reducer.reduce(halted, .bufferArrived(atMS: 2_100)) == halted)
    #expect(Reducer.reduce(.idle, .bufferArrived(atMS: 2_100)) == .idle)
}

@Test func routeChangeMediaResetAndWriteFailureAllHalt() {
    let recording = WatchRecordingPhase.recording(startedAtMS: 0, lastBufferAtMS: 500)
    #expect(Reducer.reduce(recording, .configurationChanged(atMS: 10))
        == .halted(reason: .routeChanged, atMS: 10, detail: nil))
    #expect(Reducer.reduce(recording, .mediaServicesReset(atMS: 20))
        == .halted(reason: .mediaServicesReset, atMS: 20, detail: nil))
    #expect(Reducer.reduce(recording, .writeFailed(atMS: 30, message: "disk full"))
        == .halted(reason: .writeFailed, atMS: 30, detail: "disk full"))
}

@Test func becomingActiveAfterAGapHaltsWithNoAudio() {
    let phase = Reducer.reduce(.recording(startedAtMS: 0, lastBufferAtMS: 1_000), .becameActive(atMS: 6_001))
    #expect(phase == .halted(reason: .noAudio, atMS: 6_001, detail: nil))
}

@Test func becomingActiveWithinTheGapKeepsRecording() {
    let recording = WatchRecordingPhase.recording(startedAtMS: 0, lastBufferAtMS: 1_000)
    #expect(Reducer.reduce(recording, .becameActive(atMS: 6_000)) == recording)
}

@Test func becomingActiveWithoutAnyBufferUsesTheStartTime() {
    let phase = Reducer.reduce(.recording(startedAtMS: 0, lastBufferAtMS: nil), .becameActive(atMS: 5_001))
    #expect(phase == .halted(reason: .noAudio, atMS: 5_001, detail: nil))
}

@Test func staleRecordingIsShownAsAnAlertNotAsRecording() {
    let recording = WatchRecordingPhase.recording(startedAtMS: 0, lastBufferAtMS: 1_000)
    let stale = Reducer.display(recording, nowMS: 6_001)
    #expect(stale.isActive)
    #expect(stale.message == IndicatorMessage(severity: .alert, text: "音声が届いていません"))
    let fresh = Reducer.display(recording, nowMS: 6_000)
    #expect(fresh.message == IndicatorMessage(severity: .normal, text: "録音中"))
}

@Test func becomingActiveWithAQueuedBufferIsNotStale() {
    let recording = WatchRecordingPhase.recording(startedAtMS: 0, lastBufferAtMS: 1_000)
    #expect(Reducer.reduce(recording, .becameActive(atMS: 60_000), queueDepth: 1) == recording)
    let halted = Reducer.reduce(recording, .becameActive(atMS: 60_000), queueDepth: 0)
    #expect(halted == .halted(reason: .noAudio, atMS: 60_000, detail: nil))
}

@Test func queuedBuffersKeepTheDisplayAsRecording() {
    let recording = WatchRecordingPhase.recording(startedAtMS: 0, lastBufferAtMS: 1_000)
    let queued = Reducer.display(recording, nowMS: 60_000, queueDepth: 3)
    #expect(queued.message == IndicatorMessage(severity: .normal, text: "録音中"))
    let empty = Reducer.display(recording, nowMS: 60_000, queueDepth: 0)
    #expect(empty.message == IndicatorMessage(severity: .alert, text: "音声が届いていません"))
}

@Test func stopAlwaysReturnsToIdle() {
    #expect(Reducer.reduce(.recording(startedAtMS: 0, lastBufferAtMS: nil), .stopped(atMS: 1)) == .idle)
    #expect(Reducer.reduce(.halted(reason: .noAudio, atMS: 0, detail: nil), .stopped(atMS: 1)) == .idle)
}

@Test func startFailureFromIdleHalts() {
    #expect(Reducer.reduce(.idle, .startFailed(atMS: 1, message: "x"))
        == .halted(reason: .startFailed, atMS: 1, detail: "x"))
}

@Test func restartAfterAHaltRecordsAgain() {
    let halted = WatchRecordingPhase.halted(reason: .writeFailed, atMS: 5, detail: "x")
    #expect(Reducer.reduce(halted, .started(atMS: 10)) == .recording(startedAtMS: 10, lastBufferAtMS: nil))
}

@Test func secondStartWhileRecordingIsIgnored() {
    let recording = WatchRecordingPhase.recording(startedAtMS: 100, lastBufferAtMS: 500)
    #expect(Reducer.reduce(recording, .started(atMS: 200)) == recording)
}
