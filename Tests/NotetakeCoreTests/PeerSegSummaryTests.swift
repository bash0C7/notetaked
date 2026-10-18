import Testing
@testable import NotetakeCore

private func summary(_ device: String, at receivedAt: Int64, platform: Platform?) -> PeerSegSummary {
    PeerSegSummary(device: device, deviceName: device, receivedAt: receivedAt, outcome: .current, platform: platform)
}

@Test func latestPicksTheNewestOfThePlatform() {
    let items = [
        summary("watch-old", at: 100, platform: .watchos),
        summary("watch-new", at: 300, platform: .watchos),
        summary("phone", at: 500, platform: .ios),
    ]
    #expect(PeerSegSummary.latest(items, platform: .watchos)?.device == "watch-new")
    #expect(PeerSegSummary.latest(items, platform: .ios)?.device == "phone")
}

@Test func missingPlatformCountsAsIPhone() {
    let items = [summary("old-phone", at: 100, platform: nil), summary("watch", at: 900, platform: .watchos)]
    #expect(PeerSegSummary.latest(items, platform: .ios)?.device == "old-phone")
    #expect(PeerSegSummary.latest(items, platform: .watchos)?.device == "watch")
}

@Test func noneOfThePlatformIsNil() {
    #expect(PeerSegSummary.latest([summary("phone", at: 1, platform: .ios)], platform: .watchos) == nil)
    #expect(PeerSegSummary.latest([], platform: .ios) == nil)
}
