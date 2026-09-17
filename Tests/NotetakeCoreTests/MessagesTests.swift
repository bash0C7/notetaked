import Foundation
import Testing
@testable import NotetakeCore

@Test func commandExactStrings() throws {
    #expect(try Command.start.encodedLine() == "{\"cmd\":\"start\"}")
    #expect(
        try Command.renameSpeaker(id: "g3", name: "田中").encodedLine()
            == "{\"cmd\":\"rename_speaker\",\"name\":\"田中\",\"speaker\":\"g3\"}"
    )
    #expect(try Command.rotate.encodedLine() == "{\"cmd\":\"rotate\"}")
    #expect(
        try Command.pairCode("123456").encodedLine()
            == "{\"cmd\":\"pair_code\",\"code\":\"123456\"}"
    )
}

@Test func commandRoundTrip() throws {
    let commands: [Command] = [
        .start,
        .stop,
        .renameSpeaker(id: "g3", name: "田中"),
        .rotate,
        .pairCode("123456"),
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
        platform: .mac,
        ownerLabel: "bash",
        input: "MacBook Airのマイク",
        sources: [UUID()],
        devices: ["mac-1"],
        direction: nil,
        locationInput: "MacBook Airのマイク",
        locationPlatform: .mac,
        locationSource: .mic,
        locationDirection: nil,
        locationLevelDBFS: nil
    )
    let utteranceEvent = Event.utterance(utterance)
    let volatileEvent = Event.volatile(source: .mic, text: "…")
    let errorEvent = Event.error("something failed")
    let logEvent = Event.log("started recording")
    let peerEvent = Event.peer(device: "iphone-1", deviceName: "bash iPhone", connected: true)

    let events: [Event] = [
        statusEvent, utteranceEvent, volatileEvent, errorEvent, logEvent, peerEvent,
    ]
    for event in events {
        let line = try event.encodedLine()
        #expect(try Event.decode(line: line) == event)
    }

    let utteranceLine = try utteranceEvent.encodedLine()
    #expect(utteranceLine.contains("\"speaker_id\""))
    #expect(utteranceLine.contains("\"ev\":\"utterance\""))
}

@Test func peerEventExactString() throws {
    let event = Event.peer(device: "iphone-1", deviceName: "bash iPhone", connected: true)
    #expect(
        try event.encodedLine()
            == "{\"connected\":true,\"device\":\"iphone-1\",\"device_name\":\"bash iPhone\",\"ev\":\"peer\"}"
    )
}

@Test func statusEventNilPrefixOmitsKey() throws {
    let event = Event.status(StatusEvent(recording: false, sources: [], outputDirectory: "/tmp/out"))
    let line = try event.encodedLine()
    #expect(!line.contains("\"prefix\""))
    #expect(try Event.decode(line: line) == event)
}

@Test func statusEventCarriesInputDevice() throws {
    let status = StatusEvent(
        recording: true,
        prefix: "2026-09-13T10-00-00",
        sources: [.mic],
        inputName: "MacBook Airのマイク",
        inputSpatial: false,
        outputDirectory: "/tmp"
    )
    let line = try Event.status(status).encodedLine()
    #expect(line.contains("\"input_name\":\"MacBook Airのマイク\""))
    #expect(line.contains("\"input_spatial\":false"))
}

@Test func statusEventWithoutInputOmitsKeys() throws {
    let status = StatusEvent(recording: false, sources: [], outputDirectory: "/tmp")
    let line = try Event.status(status).encodedLine()
    #expect(!line.contains("input_name"))
}

@Test func unknownEventThrows() {
    #expect(throws: ControlError.unknownEvent("nope")) {
        try Event.decode(line: "{\"ev\":\"nope\"}")
    }
}
