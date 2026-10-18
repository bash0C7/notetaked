import Foundation
import Testing
@testable import NotetakeCore

@Test func retentionDefaults() {
    #expect(RetentionPolicy.obsDays == 30)
    #expect(RetentionPolicy.receiptDays == 30)
    #expect(RetentionPolicy.failedInboxDays == 7)
}

@Test func expiredFilesAreOlderThanTheDays() {
    let day: Int64 = 86_400_000
    let now: Int64 = 100 * day
    let files: [(name: String, modifiedMS: Int64)] = [
        ("exact", now - 30 * day),
        ("just-over", now - 30 * day - 1),
        ("fresh", now - day),
    ]
    #expect(RetentionPolicy.expired(files: files, nowMS: now, days: 30) == ["just-over"])
    #expect(RetentionPolicy.expired(files: [], nowMS: now, days: 30).isEmpty)
}
