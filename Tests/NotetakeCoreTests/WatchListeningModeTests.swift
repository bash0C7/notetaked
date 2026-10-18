import Foundation
import Testing
@testable import NotetakeCore

private func enabledMode(at ms: Int64 = 1_000) -> WatchListeningMode {
    var mode = WatchListeningMode()
    mode.enable(atMS: ms)
    return mode
}

@Test func disabledStops() {
    #expect(WatchListeningMode().decide(nowMS: 5, isMicRecording: false) == .stop)
}

@Test func enabledPlays() {
    #expect(enabledMode().decide(nowMS: 2_000, isMicRecording: false) == .play)
}

@Test func autoOffAfterTwelveHours() {
    let mode = enabledMode(at: 1_000)
    #expect(mode.decide(nowMS: 1_000 + WatchListeningMode.autoOffMS - 1, isMicRecording: false) == .play)
    #expect(mode.decide(nowMS: 1_000 + WatchListeningMode.autoOffMS, isMicRecording: false) == .stopAndDisable)
}

@Test func micRecordingPausesTheSilence() {
    #expect(enabledMode().decide(nowMS: 2_000, isMicRecording: true) == .stop)
}

@Test func resumesAfterMicRecording() {
    let mode = enabledMode()
    #expect(mode.decide(nowMS: 2_000, isMicRecording: true) == .stop)
    #expect(mode.decide(nowMS: 3_000, isMicRecording: false) == .play)
}

@Test func expiredModeDisablesEvenWhileMicRecording() {
    let mode = enabledMode(at: 0)
    #expect(mode.decide(nowMS: WatchListeningMode.autoOffMS, isMicRecording: true) == .stopAndDisable)
}

@Test func disableClearsTheStamp() {
    var mode = enabledMode()
    mode.disable()
    #expect(mode == WatchListeningMode())
}

@Test func modeRoundTrips() throws {
    let mode = enabledMode(at: 42)
    let data = try JSONEncoder().encode(mode)
    #expect(try JSONDecoder().decode(WatchListeningMode.self, from: data) == mode)
}

@Test func enabledWithoutStampDisables() {
    let mode = WatchListeningMode(enabled: true, enabledAtMS: nil)
    #expect(mode.decide(nowMS: 5, isMicRecording: false) == .stopAndDisable)
    #expect(mode.remainingUntilAutoOffMS(nowMS: 5) == 0)
}

@Test func remainingUntilAutoOff() {
    let mode = enabledMode(at: 1_000)
    #expect(mode.remainingUntilAutoOffMS(nowMS: 1_000) == WatchListeningMode.autoOffMS)
    #expect(mode.remainingUntilAutoOffMS(nowMS: 1_000 + WatchListeningMode.autoOffMS - 7) == 7)
    #expect(mode.remainingUntilAutoOffMS(nowMS: 1_000 + WatchListeningMode.autoOffMS + 9) == 0)
    #expect(WatchListeningMode().remainingUntilAutoOffMS(nowMS: 0) == nil)
}
