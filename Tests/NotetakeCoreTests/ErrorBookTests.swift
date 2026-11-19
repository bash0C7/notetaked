import Foundation
import Testing
@testable import NotetakeCore

private let enospc = #"system: 生音声を書けません: Error Domain=NSCocoaErrorDomain Code=640 "The file couldn’t be saved because there isn’t enough space." UserInfo={NSUnderlyingError=0x77a6fa01b0 {Error Domain=NSPOSIXErrorDomain Code=28 "No space left on device"}}"#

@Test func summaryCutsTheCocoaErrorAndNamesTheCause() {
    #expect(ErrorText.summary(enospc) == "system: 生音声を書けません（ディスクの空きがありません）")
    #expect(ErrorText.summary("already recording") == "already recording")
}

@Test func summaryCutsTheCocoaErrorWithoutGuessingACause() {
    #expect(ErrorText.summary(#"mic: 生音声を書けません: Error Domain=NSCocoaErrorDomain Code=4 "x""#) == "mic: 生音声を書けません")
}

@Test func summaryNamesTheCauseFromTheCocoaCodeAlone() {
    #expect(
        ErrorText.summary(#"mic: 生音声を書けません: Error Domain=NSCocoaErrorDomain Code=640 "The file couldn’t be saved.""#)
            == "mic: 生音声を書けません（ディスクの空きがありません）")
}

@Test func setKeepsTheFirstTime() {
    var book = ErrorBook()
    book.set(key: "capture.system", message: enospc, nowMS: 1_000)
    book.set(key: "capture.system", message: enospc, nowMS: 9_000)
    let entries = book.active(nowMS: 9_000)
    #expect(entries.count == 1)
    #expect(entries[0].sinceMS == 1_000)
    #expect(entries[0].summary == "system: 生音声を書けません（ディスクの空きがありません）")
    #expect(entries[0].detail == enospc)
}

@Test func detailIsNilWhenTheSummaryIsTheSameText() {
    var book = ErrorBook()
    book.set(key: "a", message: "already recording", nowMS: 0)
    #expect(book.active(nowMS: 0)[0].detail == nil)
}

@Test func setUpdatesTheTextOfTheSameKey() {
    var book = ErrorBook()
    book.set(key: "a", message: "first", nowMS: 1_000)
    book.set(key: "a", message: "second", nowMS: 2_000)
    #expect(book.active(nowMS: 2_000).map(\.summary) == ["second"])
}

@Test func activeIsOrderedBySinceTime() {
    var book = ErrorBook()
    book.set(key: "late", message: "x", nowMS: 5_000)
    book.set(key: "early", message: "y", nowMS: 1_000)
    #expect(book.active(nowMS: 5_000).map(\.key) == ["early", "late"])
}

@Test func activeOrdersEqualTimesByKey() {
    var book = ErrorBook()
    book.set(key: "b", message: "x", nowMS: 1_000)
    book.set(key: "a", message: "y", nowMS: 1_000)
    #expect(book.active(nowMS: 1_000).map(\.key) == ["a", "b"])
}

@Test func resolveRemovesOnlyThatKey() {
    var book = ErrorBook()
    book.set(key: "a", message: "x", nowMS: 0)
    book.set(key: "b", message: "y", nowMS: 0)
    book.resolve(key: "a")
    #expect(book.active(nowMS: 0).map(\.key) == ["b"])
}

@Test func resolveAllWithPrefix() {
    var book = ErrorBook()
    book.set(key: "serve:archive.live", message: "x", nowMS: 0)
    book.set(key: "serve:final.p", message: "y", nowMS: 0)
    book.set(key: "polish", message: "z", nowMS: 0)
    book.resolveAll(withPrefix: "serve:")
    #expect(book.active(nowMS: 0).map(\.key) == ["polish"])
}

@Test func transientErrorExpiresAfterTenSeconds() {
    var book = ErrorBook()
    book.addTransient(message: "already recording", nowMS: 1_000)
    book.addTransient(message: "not recording", nowMS: 2_000)
    #expect(book.active(nowMS: 10_999).count == 2)
    #expect(book.active(nowMS: 11_000).map(\.summary) == ["not recording"])
    #expect(book.nextExpiryMS == 11_000)
    book.prune(nowMS: 12_000)
    #expect(book.active(nowMS: 12_000).isEmpty)
    #expect(book.nextExpiryMS == nil)
}

@Test func transientErrorsGetDistinctKeys() {
    var book = ErrorBook()
    book.addTransient(message: "same", nowMS: 0)
    book.addTransient(message: "same", nowMS: 0)
    #expect(Set(book.active(nowMS: 0).map(\.key)).count == 2)
}
