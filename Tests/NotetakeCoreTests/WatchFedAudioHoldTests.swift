import Testing
@testable import NotetakeCore

@Test func heldAudioIsReleasedOnlyAfterStreamFinishedSuccessfully() {
    var hold = WatchFedAudioHold()
    hold.hold(session: "100", id: "a")
    hold.hold(session: "100", id: "b")
    #expect(hold.release(session: "100", finishSucceeded: true).sorted() == ["a", "b"])
    #expect(hold.heldCount == 0)
}

@Test func failedFinishKeepsTheAudioHeld() {
    var hold = WatchFedAudioHold()
    hold.hold(session: "100", id: "a")
    #expect(hold.release(session: "100", finishSucceeded: false).isEmpty)
    #expect(hold.heldCount == 1)
    // 次に閉じられた時には出せる
    #expect(hold.release(session: "100", finishSucceeded: true) == ["a"])
}

@Test func releaseTouchesOnlyTheFinishedSession() {
    var hold = WatchFedAudioHold()
    hold.hold(session: "100", id: "a")
    hold.hold(session: "200", id: "z")
    #expect(hold.release(session: "100", finishSucceeded: true) == ["a"])
    #expect(hold.heldCount == 1)
    #expect(hold.release(session: "300", finishSucceeded: true).isEmpty)
}

@Test func holdingTheSameIDTwiceReleasesItOnce() {
    var hold = WatchFedAudioHold()
    hold.hold(session: "100", id: "a")
    hold.hold(session: "100", id: "a")
    #expect(hold.release(session: "100", finishSucceeded: true) == ["a"])
}
