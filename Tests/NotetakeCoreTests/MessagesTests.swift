import Foundation
import Testing
@testable import NotetakeCore

@Test func commandExactStrings() throws {
    #expect(try Command.start.encodedLine() == "{\"cmd\":\"start\"}")
    #expect(
        try Command.renameSpeaker(id: "g3", name: "田中").encodedLine()
            == "{\"cmd\":\"rename_speaker\",\"name\":\"田中\",\"speaker\":\"g3\"}"
    )
}

@Test func commandRoundTrip() throws {
    let commands: [Command] = [
        .start,
        .stop,
        .renameSpeaker(id: "g3", name: "田中"),
        .quit,
    ]
    for command in commands {
        let line = try command.encodedLine()
        #expect(try Command.decode(line: line) == command)
    }
}

@Test func eventRoundTrip() throws {
    let statusEvent = Event.status(
        StatusEvent(recording: true, prefix: "2026-09-12", sources: [.mic, .system], outputDirectory: "/tmp/out")
    )
    let utterance = Utterance(
        id: UUID(),
        start: 1_000,
        end: 2_000,
        speakerID: "g1",
        speaker: "Bash",
        text: "こんにちは",
        confidence: 0.9,
        source: .mic,
        ownerLabel: "bash",
        sources: [UUID()],
        devices: ["mac-1"]
    )
    let utteranceEvent = Event.utterance(utterance)
    let volatileEvent = Event.volatile(source: .mic, text: "…")
    let errorEvent = Event.error("something failed")
    let logEvent = Event.log("started recording")

    let events: [Event] = [statusEvent, utteranceEvent, volatileEvent, errorEvent, logEvent]
    for event in events {
        let line = try event.encodedLine()
        #expect(try Event.decode(line: line) == event)
    }

    let utteranceLine = try utteranceEvent.encodedLine()
    #expect(utteranceLine.contains("\"speaker_id\""))
    #expect(utteranceLine.contains("\"ev\":\"utterance\""))
}

@Test func unknownEventThrows() {
    #expect(throws: ControlError.unknownEvent("nope")) {
        try Event.decode(line: "{\"ev\":\"nope\"}")
    }
}
