import Foundation
import Testing
@testable import NotetakeCore

private func status(recording: Bool = true, capture: [CaptureStatus]? = nil) -> Event {
    .status(StatusEvent(recording: recording, sources: [.mic, .system], outputDirectory: "/o", capture: capture))
}

@Test func keyedErrorStandsAsServeKey() {
    var book = ErrorBook()
    AppErrorRules.apply(event: .error("failed to append segment: x", key: "archive.live"), to: &book, nowMS: 1_000)
    let entries = book.active(nowMS: 1_000)
    #expect(entries.map(\.key) == [AppErrorKey.serve("archive.live")])
    #expect(entries[0].expiresAtMS == nil)
}

@Test func unkeyedErrorIsTransient() {
    var book = ErrorBook()
    AppErrorRules.apply(event: .error("already recording"), to: &book, nowMS: 1_000)
    let entries = book.active(nowMS: 1_000)
    #expect(entries.count == 1)
    #expect(entries[0].expiresAtMS == 1_000 + ErrorBook.transientMS)
}

@Test func resolvedEventClearsTheServeKey() {
    var book = ErrorBook()
    AppErrorRules.apply(event: .error("x", key: "archive.live"), to: &book, nowMS: 0)
    AppErrorRules.apply(event: .resolved(key: "archive.live"), to: &book, nowMS: 1)
    #expect(book.active(nowMS: 1).isEmpty)
}

@Test func captureLastErrorStandsUntilTheStatusDropsIt() {
    var book = ErrorBook()
    let failing = status(capture: [CaptureStatus(source: .mic, state: .recording, lastError: "生音声を書けません")])
    AppErrorRules.apply(event: failing, to: &book, nowMS: 1_000)
    let entries = book.active(nowMS: 1_000)
    #expect(entries.map(\.key) == [AppErrorKey.capture(.mic)])
    #expect(entries[0].summary == "mic: 生音声を書けません")

    let cleared = status(capture: [CaptureStatus(source: .mic, state: .recording)])
    AppErrorRules.apply(event: cleared, to: &book, nowMS: 2_000)
    #expect(book.active(nowMS: 2_000).isEmpty)
}

@Test func captureErrorOfASourceMissingFromTheStatusIsResolved() {
    var book = ErrorBook()
    let failing = status(capture: [CaptureStatus(source: .system, state: .recording, lastError: "x")])
    AppErrorRules.apply(event: failing, to: &book, nowMS: 0)
    #expect(book.active(nowMS: 0).map(\.key) == [AppErrorKey.capture(.system)])

    AppErrorRules.apply(event: status(capture: [CaptureStatus(source: .mic, state: .recording)]), to: &book, nowMS: 1)
    #expect(book.active(nowMS: 1).isEmpty)
}

@Test func captureErrorsClearWhenRecordingStops() {
    var book = ErrorBook()
    let failing = status(capture: [
        CaptureStatus(source: .mic, state: .recording, lastError: "a"),
        CaptureStatus(source: .system, state: .recording, lastError: "b"),
    ])
    AppErrorRules.apply(event: failing, to: &book, nowMS: 0)
    #expect(book.active(nowMS: 0).count == 2)
    AppErrorRules.apply(event: status(recording: false), to: &book, nowMS: 1)
    #expect(book.active(nowMS: 1).isEmpty)
}

@Test func anyEventClearsTheDaemonError() {
    var book = ErrorBook()
    book.set(key: AppErrorKey.daemon, message: "daemon exited", nowMS: 0)
    AppErrorRules.apply(event: .log("hello"), to: &book, nowMS: 1)
    #expect(book.active(nowMS: 1).isEmpty)
}

@Test func serveStartedClearsOnlyServeKeys() {
    var book = ErrorBook()
    book.set(key: AppErrorKey.serve("archive.live"), message: "x", nowMS: 0)
    book.set(key: AppErrorKey.polish, message: "y", nowMS: 0)
    AppErrorRules.serveStarted(&book)
    #expect(book.active(nowMS: 0).map(\.key) == [AppErrorKey.polish])
}

@Test func keysHaveTheDocumentedShape() {
    #expect(AppErrorKey.capture(.mic) == "capture.mic")
    #expect(AppErrorKey.serve("final.p") == "serve:final.p")
}

@Test func serveBannerAbsorbsTheDaemonEntryAsItsReason() {
    var book = ErrorBook()
    book.set(key: AppErrorKey.daemon, message: "daemonが予期せず終了しました (signal 9)", nowMS: 0)
    book.set(key: AppErrorKey.polish, message: "整形に失敗", nowMS: 0)
    let serve = IndicatorMessage(severity: .alert, text: "serveが動いていません（signal 9）。3秒後に再起動します")

    let banners = AppErrorRules.banners(serve: serve, entries: book.active(nowMS: 0))

    #expect(
        banners.serve == ServeBanner(text: serve.text, reason: "daemonが予期せず終了しました (signal 9)"))
    #expect(banners.entries.map(\.key) == [AppErrorKey.polish])
}

@Test func daemonEntryStandsAloneWhenServeIsUp() {
    var book = ErrorBook()
    book.set(key: AppErrorKey.daemon, message: "daemonが予期せず終了しました (signal 9)", nowMS: 0)
    let entries = book.active(nowMS: 0)

    let banners = AppErrorRules.banners(serve: nil, entries: entries)

    #expect(banners.serve == nil)
    #expect(banners.entries == entries)
}

@Test func serveBannerAloneWhenThereIsNoDaemonEntry() {
    var book = ErrorBook()
    book.set(key: AppErrorKey.polish, message: "整形に失敗", nowMS: 0)
    let entries = book.active(nowMS: 0)
    let serve = IndicatorMessage(severity: .alert, text: "serveが動いていません")

    let banners = AppErrorRules.banners(serve: serve, entries: entries)

    #expect(banners.serve == ServeBanner(text: serve.text, reason: nil))
    #expect(banners.entries == entries)
}
