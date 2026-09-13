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
