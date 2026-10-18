import Foundation
import Testing
@testable import NotetakeCore

@Test func launchAfterAnUnfinishedRecordingIsInterrupted() {
    let intent = WatchRecordingIntent(wantsRecording: true, session: "1000", startedAtMS: 1_000)
    #expect(intent.interruptedOnLaunch(isRecording: false))
    #expect(intent.interruptedOnLaunch(isRecording: true) == false)
}

@Test func launchAfterAStopIsNot() {
    let intent = WatchRecordingIntent(wantsRecording: false, session: nil, startedAtMS: nil)
    #expect(intent.interruptedOnLaunch(isRecording: false) == false)
}

@Test func autoStopsAfterTenHours() {
    let intent = WatchRecordingIntent(wantsRecording: true, session: "1000", startedAtMS: 1_000)
    #expect(intent.shouldAutoStop(nowMS: 1_000 + 36_000_000))
    #expect(intent.shouldAutoStop(nowMS: 1_000 + 36_000_000 - 1) == false)
    let none = WatchRecordingIntent(wantsRecording: true, session: nil, startedAtMS: nil)
    #expect(none.shouldAutoStop(nowMS: 100_000_000_000) == false)
}

@Test func intentRoundTrips() throws {
    let intent = WatchRecordingIntent(wantsRecording: true, session: "1000", startedAtMS: 1_000)
    let data = try JSONEncoder().encode(intent)
    #expect(try JSONDecoder().decode(WatchRecordingIntent.self, from: data) == intent)
}
