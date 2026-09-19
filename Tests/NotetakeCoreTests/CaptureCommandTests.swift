import Foundation
import Testing
@testable import NotetakeCore

@Test func captureCommandStartSessionRoundTrips() throws {
    let command = CaptureCommand.startSession(directory: "/tmp/x", sources: ["mic", "system"], inputDeviceUID: "abc")
    let data = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(CaptureCommand.self, from: data)
    #expect(decoded == command)
}

@Test func captureCommandStopSessionAndQuitRoundTrip() throws {
    for command: CaptureCommand in [.stopSession, .quit] {
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(CaptureCommand.self, from: data) == command)
    }
}

@Test func captureEventAllCasesRoundTrip() throws {
    let events: [CaptureEvent] = [.started(directory: "/tmp/x"), .stopped, .inputFallback, .error("boom")]
    for event in events {
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(CaptureEvent.self, from: data) == event)
    }
}
