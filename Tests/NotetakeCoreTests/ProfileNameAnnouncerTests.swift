import Testing

@testable import NotetakeCore

@Test func namedProfileIsAnnouncedOncePerCapture() {
    let registry = SpeakerRegistry(profiles: [
        SpeakerProfile(id: "g1", name: "Kyoko", centroid: [1, 0, 0, 0], count: 3)
    ])
    var announcer = ProfileNameAnnouncer()

    #expect(announcer.record(for: "g1", in: registry) == SpeakerNameRecord(speaker: "g1", name: "Kyoko"))
    #expect(announcer.record(for: "g1", in: registry) == nil)
}

@Test func unnamedProfileIsNotAnnouncedAndStaysPending() {
    var registry = SpeakerRegistry(profiles: [
        SpeakerProfile(id: "g1", name: nil, centroid: [1, 0, 0, 0], count: 3)
    ])
    var announcer = ProfileNameAnnouncer()

    #expect(announcer.record(for: "g1", in: registry) == nil)
    registry.setName("Kyoko", for: "g1")
    // 命名前に見た idでも、名前が付いた後の初回は返す（renameの経路と重なるのはrename側が同じrecordを流すだけで無害）
    #expect(announcer.record(for: "g1", in: registry) == SpeakerNameRecord(speaker: "g1", name: "Kyoko"))
    #expect(announcer.record(for: "g1", in: registry) == nil)
}

@Test func unknownIDIsNil() {
    let registry = SpeakerRegistry()
    var announcer = ProfileNameAnnouncer()
    #expect(announcer.record(for: "g9", in: registry) == nil)
}
