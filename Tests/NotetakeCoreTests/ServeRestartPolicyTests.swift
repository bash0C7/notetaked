import Foundation
import Testing
@testable import NotetakeCore

@Test func serveRestartDelayDoublesFromOneSecondAndCapsAtThirty() {
    #expect((1...8).map { ServeRestartPolicy.delaySeconds(afterFailures: $0) } == [1, 2, 4, 8, 16, 30, 30, 30])
}

@Test func serveFailuresResetAfterRunningStably() {
    #expect(ServeRestartPolicy.consecutiveFailures(previous: 0, ranForSeconds: 1) == 1)
    #expect(ServeRestartPolicy.consecutiveFailures(previous: 3, ranForSeconds: 29) == 4)
    #expect(ServeRestartPolicy.consecutiveFailures(previous: 3, ranForSeconds: 30) == 1)
}
