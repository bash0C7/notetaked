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

@Test func captureErrorOfASourceMissingFromARecordingStatusIsKept() {
    var book = ErrorBook()
    let failing = status(capture: [CaptureStatus(source: .system, state: .recording, lastError: "x")])
    AppErrorRules.apply(event: failing, to: &book, nowMS: 0)
    #expect(book.active(nowMS: 0).map(\.key) == [AppErrorKey.capture(.system)])

    // 載っていないsourceは、治ったのか分からない
    AppErrorRules.apply(event: status(capture: [CaptureStatus(source: .mic, state: .recording)]), to: &book, nowMS: 1)
    #expect(book.active(nowMS: 1).map(\.key) == [AppErrorKey.capture(.system)])

    AppErrorRules.apply(
        event: status(capture: [CaptureStatus(source: .system, state: .recording)]), to: &book, nowMS: 2)
    #expect(book.active(nowMS: 2).isEmpty)
}

@Test func captureErrorSurvivesARecordingStatusWithoutCaptureInfo() {
    var book = ErrorBook()
    let failing = status(capture: [CaptureStatus(source: .mic, state: .recording, lastError: "生音声を書けません")])
    AppErrorRules.apply(event: failing, to: &book, nowMS: 1_000)

    // serveの再起動や収録の引き継ぎの直後は、収録中でもcaptureがまだ無い
    AppErrorRules.apply(event: status(capture: nil), to: &book, nowMS: 9_000)

    let entries = book.active(nowMS: 9_000)
    #expect(entries.map(\.key) == [AppErrorKey.capture(.mic)])
    #expect(entries[0].sinceMS == 1_000)
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
    AppErrorRules.serveStarted(&book, nowMS: 0)
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

@Test func captureDaemonErrorStandsWhileAnySourceReportsItUnresponsive() {
    var book = ErrorBook()
    let unresponsive = status(capture: [
        CaptureStatus(source: .mic, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason),
        CaptureStatus(source: .system, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason),
    ])
    AppErrorRules.apply(event: unresponsive, to: &book, nowMS: 1_000)
    let entries = book.active(nowMS: 1_000)
    #expect(entries.map(\.key) == [AppErrorKey.captureDaemon])
    #expect(entries[0].summary == CaptureActualWatcher.unresponsiveReason)

    AppErrorRules.apply(
        event: status(capture: [CaptureStatus(source: .mic, state: .recording)]), to: &book, nowMS: 2_000)
    #expect(book.active(nowMS: 2_000).isEmpty)
}

@Test func captureDaemonErrorStandsWhenItDoesNotSwitchToTheNewRecording() {
    var book = ErrorBook()
    let stuck = status(capture: [
        CaptureStatus(source: .mic, state: .retrying, reason: CaptureActualWatcher.notSwitchedReason)
    ])
    AppErrorRules.apply(event: stuck, to: &book, nowMS: 0)
    #expect(book.active(nowMS: 0).map(\.summary) == [CaptureActualWatcher.notSwitchedReason])
}

@Test func anotherRetryReasonIsNotACaptureDaemonError() {
    var book = ErrorBook()
    let retrying = status(capture: [
        CaptureStatus(source: .mic, state: .retrying, reason: "The stream was stopped by the system")
    ])
    AppErrorRules.apply(event: retrying, to: &book, nowMS: 0)
    #expect(book.active(nowMS: 0).isEmpty)
}

@Test func captureDaemonErrorClearsWhenRecordingStops() {
    var book = ErrorBook()
    let unresponsive = status(capture: [
        CaptureStatus(source: .mic, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason)
    ])
    AppErrorRules.apply(event: unresponsive, to: &book, nowMS: 0)
    AppErrorRules.apply(event: status(recording: false), to: &book, nowMS: 1)
    #expect(book.active(nowMS: 1).isEmpty)
}

@Test func keyedErrorShowsTheJapaneseSummaryAndKeepsTheOriginalAsDetail() {
    var book = ErrorBook()
    AppErrorRules.apply(
        event: .error("failed to append segment: x", key: "archive.live"), to: &book, nowMS: 1_000)
    let entry = book.active(nowMS: 1_000)[0]
    #expect(entry.summary == "収録の記録を書けません")
    #expect(entry.detail == "failed to append segment: x")
}

@Test func keyedErrorNamesTheDiskWhenTheOriginalIsOutOfSpace() {
    var book = ErrorBook()
    let message = #"failed to start session: Error Domain=NSPOSIXErrorDomain Code=28 "No space left on device""#
    AppErrorRules.apply(event: .error(message, key: "recording.start"), to: &book, nowMS: 0)
    let entry = book.active(nowMS: 0)[0]
    #expect(entry.summary == "収録を始められません（ディスクの空きがありません）")
    #expect(entry.detail == message)
}

@Test func keyedErrorOfAnUnknownKeyFallsBackToTheMessageSummary() {
    var book = ErrorBook()
    AppErrorRules.apply(event: .error("something: Error Domain=X Code=1", key: "future.key"), to: &book, nowMS: 0)
    let entry = book.active(nowMS: 0)[0]
    #expect(entry.summary == "something")
    #expect(entry.detail == "something: Error Domain=X Code=1")
}

@Test func everyServeErrorKeyHasItsJapaneseSummary() {
    #expect(ServeErrorSummary.text(forKey: "desired") == "取り込みの指示を読み書きできません")
    #expect(ServeErrorSummary.text(forKey: "recording.start") == "収録を始められません")
    #expect(ServeErrorSummary.text(forKey: "archive.live") == "収録の記録を書けません")
    #expect(ServeErrorSummary.text(forKey: "peer.other") == "端末の発話をほかの収録へ書けません")
    #expect(ServeErrorSummary.text(forKey: "peer.orphan") == "行き先の無い端末の発話を書けません")
    #expect(ServeErrorSummary.text(forKey: "peer.listener") == "端末からの接続を待ち受けられません")
    #expect(ServeErrorSummary.text(forKey: "live.mic") == "micのライブの文字起こしが止まっています")
    #expect(ServeErrorSummary.text(forKey: "live.system") == "systemのライブの文字起こしが止まっています")
    #expect(ServeErrorSummary.text(forKey: "final.2026-11-19_100000") == "2026-11-19_100000の確定処理に失敗しています")
    #expect(ServeErrorSummary.text(forKey: "unknown") == nil)
}

@Test func theSummaryTableCoversEveryKeyAServeOperationCanReport() {
    let operations: [ServeOperation] = [
        .desiredState, .startRecording, .appendLive, .appendPeerOther, .appendOrphan, .startPeerListener,
        .liveTranscription(.mic), .liveTranscription(.system), .finalize(prefix: "a"),
    ]
    for operation in operations {
        #expect(ServeErrorSummary.text(forKey: operation.errorKey) != nil)
    }
}

@Test func captureDaemonErrorSurvivesARecordingStatusWithoutCaptureInfo() {
    var book = ErrorBook()
    let unresponsive = status(capture: [
        CaptureStatus(source: .mic, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason)
    ])
    AppErrorRules.apply(event: unresponsive, to: &book, nowMS: 1_000)

    // serveの再起動や引き継ぎの直後は、収録中でもcaptureがまだ無い。治ったのか分からない
    AppErrorRules.apply(event: status(capture: nil), to: &book, nowMS: 9_000)

    let entries = book.active(nowMS: 9_000)
    #expect(entries.map(\.key) == [AppErrorKey.captureDaemon])
    #expect(entries[0].sinceMS == 1_000)
}

// MARK: - 取り込みが続けて再試行になっている

private func retrying(_ source: Source = .system, reason: String? = "TCC denied") -> Event {
    status(capture: [CaptureStatus(source: source, state: .retrying, reason: reason)])
}

private func retryingEntries(_ book: ErrorBook, nowMS: Int64) -> [ErrorEntry] {
    book.active(nowMS: nowMS).filter { $0.key == AppErrorKey.captureRetrying(.system) }
}

@Test func retryingUnderTheThresholdIsNotAnError() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 1_000)
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: 1_000 + AppErrorRules.retryingAlertMS - 1)
    #expect(book.active(nowMS: 1_000).isEmpty)
}

@Test func retryingForTheThresholdBecomesAnErrorSinceItStarted() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 1_000)
    let at = 1_000 + AppErrorRules.retryingAlertMS
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: at)
    let entries = retryingEntries(book, nowMS: at)
    #expect(entries.count == 1)
    #expect(entries[0].summary == "system: 取り込めていません（TCC denied）")
    #expect(entries[0].sinceMS == 1_000)
}

@Test func retryingWithoutAReasonOmitsTheParenthesis() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(reason: nil), to: &book, tracker: &tracker, nowMS: 0)
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: AppErrorRules.retryingAlertMS)
    #expect(retryingEntries(book, nowMS: AppErrorRules.retryingAlertMS).map(\.summary) == ["system: 取り込めていません"])
}

@Test func repeatedRetryingStatusesDoNotRestartTheCount() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 1_000)
    AppErrorRules.apply(event: retrying(reason: "別の理由"), to: &book, tracker: &tracker, nowMS: 8_000)
    let at = 1_000 + AppErrorRules.retryingAlertMS
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: at)
    let entries = retryingEntries(book, nowMS: at)
    #expect(entries[0].sinceMS == 1_000)
    #expect(entries[0].summary == "system: 取り込めていません（別の理由）")
}

@Test func retryingErrorResolvesWhenTheSourceRecordsAgain() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 0)
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: 20_000)
    #expect(!retryingEntries(book, nowMS: 20_000).isEmpty)

    let recovered = status(capture: [CaptureStatus(source: .system, state: .recording)])
    AppErrorRules.apply(event: recovered, to: &book, tracker: &tracker, nowMS: 21_000)
    #expect(book.active(nowMS: 21_000).isEmpty)
    #expect(tracker.isEmpty)
}

@Test func recoveryBeforeTheThresholdCancelsThePromotion() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 0)
    let recovered = status(capture: [CaptureStatus(source: .system, state: .recording)])
    AppErrorRules.apply(event: recovered, to: &book, tracker: &tracker, nowMS: 5_000)
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: 30_000)
    #expect(book.active(nowMS: 30_000).isEmpty)
}

@Test func retryingErrorAndTrackerClearWhenRecordingStops() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 0)
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: 20_000)
    AppErrorRules.apply(event: status(recording: false), to: &book, tracker: &tracker, nowMS: 21_000)
    #expect(book.active(nowMS: 21_000).isEmpty)
    #expect(tracker.isEmpty)
}

@Test func retryingStateSurvivesARecordingStatusWithoutCaptureInfo() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    AppErrorRules.apply(event: retrying(), to: &book, tracker: &tracker, nowMS: 0)
    AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: 20_000)
    AppErrorRules.apply(event: status(capture: nil), to: &book, tracker: &tracker, nowMS: 21_000)
    #expect(!retryingEntries(book, nowMS: 21_000).isEmpty)
    #expect(!tracker.isEmpty)
}

@Test func daemonUnresponsiveRetryingIsNotReportedPerSource() {
    for reason in [CaptureActualWatcher.unresponsiveReason, CaptureActualWatcher.notSwitchedReason] {
        var book = ErrorBook()
        var tracker = CaptureRetryTracker()
        AppErrorRules.apply(event: retrying(reason: reason), to: &book, tracker: &tracker, nowMS: 0)
        AppErrorRules.promoteRetrying(&book, tracker: tracker, nowMS: 60_000)
        #expect(book.active(nowMS: 60_000).map(\.key) == [AppErrorKey.captureDaemon])
        #expect(tracker.isEmpty)
    }
}

@Test func nextRetryingDeadlineIsTheEarliestStartPlusTheThreshold() {
    var book = ErrorBook()
    var tracker = CaptureRetryTracker()
    #expect(AppErrorRules.nextRetryingDeadlineMS(tracker: tracker, nowMS: 0) == nil)

    AppErrorRules.apply(event: retrying(.system), to: &book, tracker: &tracker, nowMS: 3_000)
    AppErrorRules.apply(event: retrying(.mic), to: &book, tracker: &tracker, nowMS: 5_000)
    #expect(AppErrorRules.nextRetryingDeadlineMS(tracker: tracker, nowMS: 6_000) == 3_000 + AppErrorRules.retryingAlertMS)
    // 期限を過ぎたものは数えない。数えると同じ時刻で予約を繰り返す
    #expect(AppErrorRules.nextRetryingDeadlineMS(tracker: tracker, nowMS: 14_000) == 5_000 + AppErrorRules.retryingAlertMS)
    #expect(AppErrorRules.nextRetryingDeadlineMS(tracker: tracker, nowMS: 15_000) == nil)
}
