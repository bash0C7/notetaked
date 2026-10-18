import Foundation
import Testing
@testable import NotetakeCore

private let recording = WatchRecordingPhase.recording(startedAtMS: 1_000, lastBufferAtMS: nil)
private let halted = WatchRecordingPhase.halted(reason: .interrupted, atMS: 5_000, detail: nil)

@Test func startSchedulesTheGrace() {
    let action = WatchDeadMan.action(
        for: .started(atMS: 1_000), chunkClosedAtMS: nil, previous: .idle, next: recording)
    #expect(action == .schedule(fireAtMS: 1_000 + 180_000))
}

@Test func eachClosedChunkPushesTheDeadlineForward() {
    let action = WatchDeadMan.action(
        for: nil, chunkClosedAtMS: 21_000, previous: recording, next: recording)
    #expect(action == .schedule(fireAtMS: 21_000 + 180_000))
}

@Test func closedChunkAfterHaltDoesNotReschedule() {
    let action = WatchDeadMan.action(for: nil, chunkClosedAtMS: 21_000, previous: halted, next: halted)
    #expect(action == .none)
}

@Test func stopCancels() {
    let action = WatchDeadMan.action(
        for: .stopped(atMS: 9_000), chunkClosedAtMS: nil, previous: recording, next: .idle)
    #expect(action == .cancel)
}

@Test func haltCancelsTheDelayedOne() {
    let action = WatchDeadMan.action(
        for: .interruptionBegan(atMS: 5_000), chunkClosedAtMS: nil, previous: recording, next: halted)
    #expect(action == .cancel)
}

@Test func autoStopCancels() {
    let autoHalted = WatchRecordingPhase.halted(reason: .autoStopped, atMS: 5_000, detail: nil)
    let action = WatchDeadMan.action(
        for: .autoStopped(atMS: 5_000), chunkClosedAtMS: nil, previous: recording, next: autoHalted)
    #expect(action == .cancel)
}

@Test func startFailedFromIdleDoesNothing() {
    let failed = WatchRecordingPhase.halted(reason: .startFailed, atMS: 1_000, detail: "x")
    let action = WatchDeadMan.action(
        for: .startFailed(atMS: 1_000, message: "x"), chunkClosedAtMS: nil, previous: .idle, next: failed)
    #expect(action == .none)
}

@Test func idleDoesNothing() {
    #expect(WatchDeadMan.action(for: nil, chunkClosedAtMS: nil, previous: .idle, next: .idle) == .none)
    #expect(
        WatchDeadMan.action(for: .bufferArrived(atMS: 2_000), chunkClosedAtMS: nil, previous: .idle, next: .idle)
            == .none)
}
