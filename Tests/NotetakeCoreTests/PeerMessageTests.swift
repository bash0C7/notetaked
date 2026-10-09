import Foundation
import Testing
@testable import NotetakeCore

private func makeSegmentFixture() -> Segment {
    Segment(
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
}

@Test func peerMessageExactStrings() throws {
    #expect(
        try PeerMessage.hello(
            HelloMessage(device: "iphone-1", deviceName: "bash iPhone", owner: "bash", platform: .ios, protocolVersion: 1)
        ).encodedLine()
            == "{\"device\":\"iphone-1\",\"device_name\":\"bash iPhone\",\"owner\":\"bash\",\"platform\":\"ios\",\"protocol_version\":1,\"t\":\"hello\"}"
    )
    #expect(
        try PeerMessage.ping(id: 7, t0: 1_000).encodedLine()
            == "{\"id\":7,\"t\":\"ping\",\"t0\":1000}"
    )
    #expect(
        try PeerMessage.pong(id: 7, t0: 1_000, t1: 1_010, t2: 1_015).encodedLine()
            == "{\"id\":7,\"t\":\"pong\",\"t0\":1000,\"t1\":1010,\"t2\":1015}"
    )
    #expect(
        try PeerMessage.ack(seq: 42).encodedLine()
            == "{\"seq\":42,\"t\":\"ack\"}"
    )
}

@Test func peerMessageRoundTrip() throws {
    let messages: [PeerMessage] = [
        .hello(HelloMessage(device: "iphone-1", deviceName: "bash iPhone", owner: "bash", platform: .ios, protocolVersion: 1)),
        .helloAck(HelloAckMessage(serverTimeMS: 1_700_000_000_000, accepted: true, reason: nil)),
        .helloAck(HelloAckMessage(serverTimeMS: 1_700_000_000_000, accepted: false, reason: "pairing code mismatch")),
        .ping(id: 1, t0: 1_000),
        .pong(id: 1, t0: 1_000, t1: 1_010, t2: 1_015),
        .seg(makeSegmentFixture()),
        .ack(seq: 3),
    ]
    for message in messages {
        let line = try message.encodedLine()
        #expect(try PeerMessage.decode(line: line) == message)
    }
}

@Test func peerMessageSegUsesSegmentKeys() throws {
    let segment = makeSegmentFixture()
    let line = try PeerMessage.seg(segment).encodedLine()
    #expect(line.contains("\"t\":\"seg\""))
    #expect(line.contains("\"device_name\":\"bash iPhone\""))
    #expect(line.contains("\"clock_offset_ms\":-84"))
    #expect(line.contains("\"level_dbfs\":-23.5"))
}

@Test func unknownPeerMessageTypeThrows() {
    #expect(throws: PeerError.unknownType("bogus")) {
        try PeerMessage.decode(line: "{\"t\":\"bogus\"}")
    }
}

@Test func peerMessageSignalRequestExactString() throws {
    let message = PeerMessage.signalRequest(
        SignalRequestMessage(id: "r1", prefix: "p", startMS: 0, endMS: 600_000, bucketMS: 600_000, pending: 2))
    #expect(
        try message.encodedLine()
            == "{\"bucket_ms\":600000,\"end_ms\":600000,\"id\":\"r1\",\"pending\":2,\"prefix\":\"p\",\"start_ms\":0,\"t\":\"signal_request\"}")
    #expect(try PeerMessage.decode(line: try message.encodedLine()) == message)
}

@Test func peerMessageSignalResponseExactString() throws {
    let message = PeerMessage.signalResponse(
        SignalResponseMessage(
            id: "r1", prefix: "p", sources: SignalSources(hr: .ok, hrv: .empty, place: .always),
            buckets: [SignalBucket(start: 0, end: 600_000, hr: HeartRateSummary(mean: 72, min: nil, max: nil, n: 1))]))
    #expect(
        try message.encodedLine()
            == "{\"buckets\":[{\"end\":600000,\"hr\":{\"mean\":72,\"n\":1},\"hrv\":null,\"start\":0}],\"id\":\"r1\",\"prefix\":\"p\",\"sources\":{\"hr\":\"ok\",\"hrv\":\"empty\",\"place\":\"always\"},\"t\":\"signal_response\"}")
    #expect(try PeerMessage.decode(line: try message.encodedLine()) == message)
}

@Test func peerMessageSignalResponseWithUnknownStatusIsRejected() {
    let line = "{\"buckets\":[],\"id\":\"r1\",\"prefix\":\"p\",\"sources\":{\"hr\":\"stressed\",\"hrv\":\"ok\",\"place\":\"always\"},\"t\":\"signal_response\"}"
    #expect(throws: (any Error).self) { try PeerMessage.decode(line: line) }
}

@Test func helloWithCapabilitiesAnnouncesSignalAndOldHelloDoesNot() throws {
    let hello = HelloMessage(
        device: "iphone-1", deviceName: "bash iPhone", owner: "bash", platform: .ios,
        capabilities: [HelloMessage.signalCapability])
    #expect(
        try PeerMessage.hello(hello).encodedLine()
            == "{\"capabilities\":[\"signal\"],\"device\":\"iphone-1\",\"device_name\":\"bash iPhone\",\"owner\":\"bash\",\"platform\":\"ios\",\"protocol_version\":1,\"t\":\"hello\"}")
    #expect(hello.supportsSignal)
    let old = try PeerMessage.decode(
        line: "{\"device\":\"iphone-1\",\"device_name\":\"bash iPhone\",\"owner\":\"bash\",\"platform\":\"ios\",\"protocol_version\":1,\"t\":\"hello\"}")
    guard case .hello(let decoded) = old else {
        Issue.record("helloとして読めない")
        return
    }
    #expect(decoded.capabilities == nil)
    #expect(!decoded.supportsSignal)
}
