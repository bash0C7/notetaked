import Foundation
import Testing
@testable import NotetakeCore

@Test func retryBackoffDoublesUpToThirtySeconds() {
    #expect((0..<8).map { RetryBackoff.seconds(afterFailures: $0) } == [1, 2, 4, 8, 16, 30, 30, 30])
}
