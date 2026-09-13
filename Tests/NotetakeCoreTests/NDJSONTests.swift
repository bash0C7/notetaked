import Foundation
import Testing
@testable import NotetakeCore

@Test func segmentRoundTrip() throws {
    let segment = Segment(
        id: UUID(),
        session: "s1",
        seq: 3,
        device: "iphone-1",
        deviceName: "bash iPhone",
        owner: "bash",
        platform: .ios,
        source: .mic,
        input: .test,
        start: 1_000,
        end: 2_000,
        text: "こんにちは",
        confidence: 0.9,
        levelDBFS: -23.5,
        speaker: SpeakerTag(local: "l1", global: "g1", embedding: [0.1, 0.2, 0.3]),
        clockOffsetMS: -84,
        receivedAt: 1_234_567
    )
    let record = Record.segment(segment)

    let line = try NDJSON.encode(record)
    #expect(line.contains("\"t\":\"seg\""))
    #expect(line.contains("\"level_dbfs\":-23.5"))
    #expect(line.contains("\"device_name\":\"bash iPhone\""))
    #expect(line.contains("\"clock_offset_ms\":-84"))

    #expect(try NDJSON.decode(line) == record)
}

@Test func optionalFieldsOmitted() throws {
    let segment = Segment(
        id: UUID(),
        session: "s1",
        seq: 1,
        device: "d1",
        deviceName: "Device One",
        owner: "bash",
        platform: .mac,
        source: .system,
        input: .test,
        start: 0,
        end: 100,
        text: "hello"
    )

    let line = try NDJSON.encode(.segment(segment))
    #expect(!line.contains("\"confidence\""))
    #expect(!line.contains("\"speaker\""))
    #expect(!line.contains("\"received_at\""))
}

@Test func otherRecordsRoundTrip() throws {
    let sessionRecord = Record.session(SessionRecord(id: "sess-1", started: 1_700_000_000_000, owner: "bash"))
    let sessionLine = try NDJSON.encode(sessionRecord)
    #expect(sessionLine.contains("\"t\":\"session\""))
    #expect(try NDJSON.decode(sessionLine) == sessionRecord)

    let deviceRecord = Record.device(DeviceRecord(device: "mac-1", deviceName: "MacBook", owner: "bash", platform: .mac, offsetMS: 0))
    let deviceLine = try NDJSON.encode(deviceRecord)
    #expect(deviceLine.contains("\"t\":\"device\""))
    #expect(try NDJSON.decode(deviceLine) == deviceRecord)

    let speakerNameRecord = Record.speakerName(SpeakerNameRecord(speaker: "g1", name: "Bash"))
    let speakerNameLine = try NDJSON.encode(speakerNameRecord)
    #expect(speakerNameLine.contains("\"t\":\"speaker_name\""))
    #expect(try NDJSON.decode(speakerNameLine) == speakerNameRecord)
}

@Test func encodeExactString() throws {
    let record = Record.speakerName(.init(speaker: "g3", name: "田中"))
    let line = try NDJSON.encode(record)
    #expect(line == "{\"name\":\"田中\",\"speaker\":\"g3\",\"t\":\"speaker_name\"}")
}

@Test func encodeIsSingleLine() throws {
    let segment = Segment(
        id: UUID(),
        session: "s1",
        seq: 1,
        device: "d1",
        deviceName: "d",
        owner: "bash",
        platform: .mac,
        source: .mic,
        input: .test,
        start: 0,
        end: 1,
        text: "hi"
    )
    let line = try NDJSON.encode(.segment(segment))
    #expect(!line.contains("\n"))
}

@Test func unknownTypeThrows() {
    #expect(throws: NDJSONError.unknownType("bogus")) {
        try NDJSON.decode("{\"t\":\"bogus\"}")
    }
}

@Test func segmentEncodesInputAndDirection() throws {
    let segment = Segment(
        id: UUID(), session: "s1", seq: 1, device: "iphone-1", deviceName: "bash iPhone",
        owner: "bash", platform: .ios, source: .mic,
        input: InputDevice(name: "iPhone マイク", uid: "mic-1", spatial: true),
        start: 1_000, end: 2_000, text: "こんにちは",
        direction: Direction(azimuthDeg: 57.3, confidence: 0.82)
    )
    let line = try NDJSON.encode(.segment(segment))
    #expect(line.contains("\"input\":{"))
    #expect(line.contains("\"spatial\":true"))
    #expect(line.contains("\"azimuth_deg\":57.3"))
    let decoded = try NDJSON.decode(line)
    #expect(decoded == .segment(segment))
}

@Test func segmentWithoutDirectionOmitsKey() throws {
    let segment = Segment(
        id: UUID(), session: "s1", seq: 1, device: "mac-1", deviceName: "Mac",
        owner: "bash", platform: .mac, source: .mic, input: .test,
        start: 1_000, end: 2_000, text: "こんにちは"
    )
    let line = try NDJSON.encode(.segment(segment))
    #expect(!line.contains("direction"))
    #expect(line.contains("\"input\":{"))
}

@Test func decodeAllSkipsBlankAndCorruptLines() throws {
    let segment = Segment(
        id: UUID(),
        session: "s1",
        seq: 1,
        device: "d1",
        deviceName: "d",
        owner: "bash",
        platform: .mac,
        source: .mic,
        input: .test,
        start: 0,
        end: 1,
        text: "hi"
    )
    let validLine = try NDJSON.encode(.segment(segment))
    let text = [validLine, "", "{\"t\":\"seg\",\"id\":"].joined(separator: "\n")

    let records = NDJSON.decodeAll(text)
    #expect(records.count == 1)
}
