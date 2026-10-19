import Foundation
import Testing
@testable import NotetakeCore

@Suite struct StatusClockTextTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func formatsDateAndTimeToTheSecond() {
        // 2026-10-19 12:34:56 JST = 03:34:56 UTC
        let ms: Int64 = 1_792_380_896_000
        #expect(StatusClockText.text(atMS: ms, timeZone: tokyo) == "2026-10-19 12:34:56")
    }

    @Test func dropsTheFractionOfASecond() {
        let ms: Int64 = 1_792_380_896_999
        #expect(StatusClockText.text(atMS: ms, timeZone: tokyo) == "2026-10-19 12:34:56")
    }

    @Test func nilIsADash() {
        #expect(StatusClockText.text(atMS: nil, timeZone: tokyo) == "—")
    }
}
