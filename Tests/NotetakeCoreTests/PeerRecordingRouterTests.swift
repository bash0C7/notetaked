import Foundation
import Testing
@testable import NotetakeCore

private let utc = TimeZone(identifier: "UTC")!

private func segment(
    platform: Platform = .watchos, device: String = "watch1", session: String = "1760000000000", start: Int64 = 1_760_000_100_000
) -> Segment {
    Segment(
        id: UUID(), session: session, seq: 1, device: device, deviceName: device, owner: "山田太郎", platform: platform,
        source: .watch, input: .test, start: start, end: start + 1_000, text: "発話")
}

private func route(
    _ segment: Segment, normalizedStartMS: Int64? = nil, spans: [SessionSpan] = [], currentPrefix: String? = nil,
    recording: Bool = false
) -> PeerRoute {
    PeerRecordingRouter.route(
        segment: segment, normalizedStartMS: normalizedStartMS ?? segment.start, spans: spans,
        currentPrefix: currentPrefix, recording: recording, timeZone: utc)
}

private func prefixOf(_ ms: Int64) -> String {
    SessionStore.prefix(for: Date(timeIntervalSince1970: Double(ms) / 1000), timeZone: utc)
}

@Test func matchingCurrentRecordingIsCurrent() {
    let spans = [SessionSpan(prefix: "mac", startMS: 0, endMS: nil)]
    #expect(route(segment(), spans: spans, currentPrefix: "mac", recording: true) == .current)
}

@Test func currentPrefixWhileNotRecordingIsNotCurrent() {
    let spans = [SessionSpan(prefix: "mac", startMS: 0, endMS: 1_760_000_200_000)]
    #expect(route(segment(), spans: spans, currentPrefix: "mac", recording: false) == .other(prefix: "mac"))
}

@Test func matchingPastMacRecordingIsOther() {
    let spans = [SessionSpan(prefix: "old", startMS: 1_760_000_000_000, endMS: 1_760_000_200_000)]
    #expect(route(segment(), spans: spans) == .other(prefix: "old"))
}

@Test func peerSpanIsNotMatchedByTimeForAnotherDevice() {
    let spans = [
        SessionSpan(
            prefix: "p-watch", startMS: 1_760_000_000_000, endMS: 1_760_000_200_000, origin: .peer, peerKey: "watch1/1760000000000")
    ]
    let result = route(segment(device: "watch2", session: "1760000000000"), spans: spans)
    guard case .peerRecording(let prefix, let create) = result else { Issue.record("peerRecording ではない"); return }
    #expect(prefix != "p-watch")
    #expect(create != nil)
}

@Test func existingPeerRecordingIsReused() {
    let spans = [
        SessionSpan(prefix: "p-watch", startMS: 1_760_000_000_000, endMS: 1_760_000_050_000, origin: .peer, peerKey: "watch1/s9")
    ]
    #expect(route(segment(session: "s9"), spans: spans) == .peerRecording(prefix: "p-watch", create: nil))
}

@Test func newWatchSessionCreatesAWatchRecordingFromTheSessionMS() {
    let result = route(segment(session: "1760000000000"))
    let expected = prefixOf(1_760_000_000_000) + "-watch"
    guard case .peerRecording(let prefix, let create) = result else { Issue.record("peerRecording ではない"); return }
    #expect(prefix == expected)
    #expect(create == SessionRecord(
        id: expected, started: 1_760_000_000_000, owner: "山田太郎", origin: .peer, peerDevice: "watch1",
        peerSession: "1760000000000"))
}

@Test func newIPhoneSessionUsesItsPrefixTime() {
    let sessionPrefix = prefixOf(1_760_000_050_000)
    let result = route(segment(platform: .ios, device: "iphone1", session: sessionPrefix))
    guard case .peerRecording(let prefix, let create) = result else { Issue.record("peerRecording ではない"); return }
    #expect(prefix == sessionPrefix + "-iphone")
    #expect(create?.started == 1_760_000_050_000)
    #expect(create?.origin == .peer)
}

@Test func unparsableSessionUsesTheSegmentStart() {
    let result = route(segment(session: "abc"), normalizedStartMS: 1_760_000_123_000)
    guard case .peerRecording(let prefix, let create) = result else { Issue.record("peerRecording ではない"); return }
    #expect(create?.started == 1_760_000_123_000)
    #expect(prefix == prefixOf(1_760_000_123_000) + "-watch")
}

@Test func sessionStartAfterTheSegmentIsClampedToTheSegment() {
    let result = route(segment(session: "1760000999000"), normalizedStartMS: 1_760_000_100_000)
    guard case .peerRecording(_, let create) = result else { Issue.record("peerRecording ではない"); return }
    #expect(create?.started == 1_760_000_100_000)
}

@Test func prefixCollisionGetsASuffix() {
    let base = prefixOf(1_760_000_000_000) + "-watch"
    var spans = [SessionSpan(prefix: base, startMS: 0, endMS: 1, origin: .peer, peerKey: "watch1/other")]
    guard case .peerRecording(let second, _) = route(segment(), spans: spans) else { Issue.record("x"); return }
    #expect(second == base + "-2")
    spans.append(SessionSpan(prefix: second, startMS: 0, endMS: 1, origin: .peer, peerKey: "watch1/other2"))
    guard case .peerRecording(let third, _) = route(segment(), spans: spans) else { Issue.record("x"); return }
    #expect(third == base + "-3")
}

@Test func differentDeviceSameSessionGetsItsOwnRecording() {
    let first = route(segment(device: "watch1", session: "1760000000000"))
    guard case .peerRecording(let firstPrefix, let firstCreate) = first, let record = firstCreate else {
        Issue.record("peerRecording ではない"); return
    }
    let spans = [
        SessionSpan(prefix: firstPrefix, startMS: record.started, endMS: record.started, origin: .peer, peerKey: "watch1/1760000000000")
    ]
    let second = route(segment(device: "watch2", session: "1760000000000"), spans: spans)
    guard case .peerRecording(let secondPrefix, let secondCreate) = second else { Issue.record("x"); return }
    #expect(secondPrefix == firstPrefix + "-2")
    #expect(secondCreate?.peerDevice == "watch2")
}
