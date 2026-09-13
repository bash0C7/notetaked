import Foundation
import Testing
@testable import NotetakeCore

@Test func matchesActiveSessionWhenStartAfterSessionStart() {
    let sessions = [SessionSpan(prefix: "p1", startMS: 1_000, endMS: nil)]
    #expect(SessionMatcher.match(segmentStartMS: 1_500, sessions: sessions) == "p1")
}

@Test func activeSessionDoesNotMatchBeforeItStarted() {
    let sessions = [SessionSpan(prefix: "p1", startMS: 1_000, endMS: nil)]
    #expect(SessionMatcher.match(segmentStartMS: 500, sessions: sessions) == nil)
}

@Test func matchesPastSessionWithinTolerance() {
    let sessions = [SessionSpan(prefix: "p1", startMS: 1_000, endMS: 2_000)]
    #expect(SessionMatcher.match(segmentStartMS: 2_400, sessions: sessions, toleranceMS: 500) == "p1")
    #expect(SessionMatcher.match(segmentStartMS: 2_500, sessions: sessions, toleranceMS: 500) == "p1")
}

@Test func pastSessionDoesNotMatchBeyondTolerance() {
    let sessions = [SessionSpan(prefix: "p1", startMS: 1_000, endMS: 2_000)]
    #expect(SessionMatcher.match(segmentStartMS: 2_600, sessions: sessions, toleranceMS: 500) == nil)
}

@Test func prefersLatestStartWhenMultipleMatch() {
    let sessions = [
        SessionSpan(prefix: "older", startMS: 1_000, endMS: nil),
        SessionSpan(prefix: "newer", startMS: 2_000, endMS: nil),
    ]
    #expect(SessionMatcher.match(segmentStartMS: 3_000, sessions: sessions) == "newer")
}

@Test func prefersLatestStartAmongPastSessions() {
    let sessions = [
        SessionSpan(prefix: "first", startMS: 0, endMS: 5_000),
        SessionSpan(prefix: "second", startMS: 1_000, endMS: 4_000),
    ]
    #expect(SessionMatcher.match(segmentStartMS: 3_000, sessions: sessions) == "second")
}

@Test func noMatchReturnsNilForOrphan() {
    let sessions = [SessionSpan(prefix: "p1", startMS: 1_000, endMS: 2_000)]
    #expect(SessionMatcher.match(segmentStartMS: 10_000, sessions: sessions) == nil)
    #expect(SessionMatcher.match(segmentStartMS: 100, sessions: []) == nil)
}
