import Foundation
import Testing
@testable import NotetakeCore

private let wake = WatchWakeMessage(device: "watch-abc", session: "1700000000000", index: 5, sentAtMS: 4_000_000_000_000)

@Test func wakeMessageRoundTrips() {
    #expect(WatchWakeMessage(message: wake.message) == wake)
}

@Test func wakeMessageKeysAreFixed() {
    #expect(Set(wake.message.keys) == ["kind", "device", "session", "index", "sent_at_ms"])
    #expect(wake.message["kind"] as? String == "wake")
}

@Test func wakeMessageAcceptsNSNumberAndDouble() {
    var dict = wake.message
    dict["index"] = NSNumber(value: 5)
    dict["sent_at_ms"] = NSNumber(value: 4_000_000_000_000 as Int64)
    #expect(WatchWakeMessage(message: dict) == wake)
    dict["index"] = Double(5)
    dict["sent_at_ms"] = Double(4_000_000_000_000)
    #expect(WatchWakeMessage(message: dict) == wake)
}

@Test func otherKindIsNil() {
    var dict = wake.message
    dict.removeValue(forKey: "kind")
    #expect(WatchWakeMessage(message: dict) == nil)
    dict["kind"] = "wake_reply"
    #expect(WatchWakeMessage(message: dict) == nil)
    dict["kind"] = "obs"
    #expect(WatchWakeMessage(message: dict) == nil)
}

@Test func missingFieldIsNil() {
    for key in ["device", "session", "index", "sent_at_ms"] {
        var dict = wake.message
        dict.removeValue(forKey: key)
        #expect(WatchWakeMessage(message: dict) == nil)
    }
}

@Test func unknownKeysAreIgnored() {
    var dict = wake.message
    dict["future"] = "x"
    #expect(WatchWakeMessage(message: dict) == wake)
}

@Test func replyRoundTrips() {
    let reply = WatchWakeReply(receivedAtMS: 123)
    #expect(Set(reply.message.keys) == ["kind", "received_at_ms"])
    #expect(WatchWakeReply(message: reply.message) == reply)
}

@Test func replyIsNotAWake() {
    #expect(WatchWakeMessage(message: WatchWakeReply(receivedAtMS: 1).message) == nil)
}
