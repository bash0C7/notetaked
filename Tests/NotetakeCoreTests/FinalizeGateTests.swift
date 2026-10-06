import Foundation
import Testing
@testable import NotetakeCore

@Test func stallIsDeclaredAfterFiveMinutesWithoutProgress() {
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(!FinalizeStallPolicy.isStalled(lastProgress: start, now: start.addingTimeInterval(300)))
    #expect(FinalizeStallPolicy.isStalled(lastProgress: start, now: start.addingTimeInterval(301)))
    #expect(FinalizeStallPolicy.isStalled(lastProgress: start, now: start.addingTimeInterval(2), timeout: 1))
}

@Test func gateWaitsWhileCaptureDaemonStillWritesThePrefix() {
    func actual(prefix: String?, updated: Int64) -> CaptureActualState {
        CaptureActualState(pid: 1, prefix: prefix, sources: [], updated: updated)
    }
    let now: Int64 = 100_000
    #expect(!FinalizeGate.canStart(prefix: "a", actual: actual(prefix: "a", updated: now - 1_000), nowMS: now))
    #expect(FinalizeGate.canStart(prefix: "a", actual: actual(prefix: "b", updated: now - 1_000), nowMS: now))
    #expect(FinalizeGate.canStart(prefix: "a", actual: actual(prefix: nil, updated: now - 1_000), nowMS: now))
    #expect(FinalizeGate.canStart(prefix: "a", actual: actual(prefix: "a", updated: now - 6_000), nowMS: now))
    #expect(FinalizeGate.canStart(prefix: "a", actual: nil, nowMS: now))
}
