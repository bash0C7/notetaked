import Foundation
import Testing

@testable import NotetakeCore

private let started = Date(timeIntervalSince1970: 1_000)

@Test func noBufferSinceStartIsStalledOnlyAfterTheTimeout() {
    #expect(!CaptureStall.isStalled(lastBufferAt: nil, startedAt: started, now: started.addingTimeInterval(4.9)))
    #expect(CaptureStall.isStalled(lastBufferAt: nil, startedAt: started, now: started.addingTimeInterval(5.1)))
}

@Test func aRecentBufferIsNotStalled() {
    let last = started.addingTimeInterval(100)
    #expect(!CaptureStall.isStalled(lastBufferAt: last, startedAt: started, now: last.addingTimeInterval(4.9)))
}

@Test func buffersThatStopArrivingAreStalledFromTheLastOne() {
    let last = started.addingTimeInterval(100)
    #expect(CaptureStall.isStalled(lastBufferAt: last, startedAt: started, now: last.addingTimeInterval(5.1)))
}

@Test func theTimeoutIsConfigurable() {
    #expect(CaptureStall.isStalled(lastBufferAt: nil, startedAt: started, now: started.addingTimeInterval(2), timeout: 1))
}
