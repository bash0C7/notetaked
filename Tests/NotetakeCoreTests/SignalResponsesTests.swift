import Foundation
import Testing
@testable import NotetakeCore

private let minute: Int64 = 60_000

private func request(round: Int = 1, failureCount: Int = 0) -> SignalRequest {
    SignalRequest(
        id: "r1", prefix: "p", outputDirectory: "/out", recordingStartMS: 0, recordingEndMS: 30 * minute,
        startMS: 0, endMS: 20 * minute, round: round, createdAtMS: 0, dueAtMS: 0, failureCount: failureCount)
}

private func response(hr: HealthSourceStatus = .ok, hrv: HealthSourceStatus = .ok, place: PlaceSourceStatus = .always, buckets: [SignalBucket] = []) -> SignalResponseMessage {
    SignalResponseMessage(id: "r1", prefix: "p", sources: SignalSources(hr: hr, hrv: hrv, place: place), buckets: buckets)
}

private func merged(_ buckets: [SignalBucket]) -> SignalsDocument {
    SignalsDocument(header: SignalsHeader(prefix: "p", start: 0, end: 30 * minute, bucketMS: 600_000, requestedAt: 0), buckets: buckets)
}

@Test func signalResponseCompletesWhenHealthKitCouldBeRead() {
    #expect(SignalResponseHandling.outcome(request: request(), response: response(hr: .empty, hrv: .empty), nowMS: 0) == .completed)
}

@Test func signalResponseRetriesUnavailableHealthKitEveryTenMinutes() {
    var expected = request()
    expected.failureCount = 1
    expected.dueAtMS = 1_000 + 10 * minute
    #expect(SignalResponseHandling.outcome(request: request(), response: response(hr: .unavailable), nowMS: 1_000) == .retry(expected))
}

@Test func signalResponseKeepsRetryingUnavailableHealthKitWithoutALimitOnTheCount() {
    var expected = request(failureCount: 3)
    expected.failureCount = 4
    expected.dueAtMS = 10 * minute
    #expect(SignalResponseHandling.outcome(request: request(failureCount: 3), response: response(hrv: .unavailable), nowMS: 0) == .retry(expected))
}

@Test func signalResponseApplyRemovesFinishedRequestsAndUpdatesRetried() {
    let state = SignalRequestState(requests: [request()], pinnedDevice: "a")
    #expect(SignalResponseHandling.apply(.completed, to: state, requestID: "r1").requests.isEmpty)
    var retried = request()
    retried.failureCount = 1
    #expect(SignalResponseHandling.apply(.retry(retried), to: state, requestID: "r1").requests == [retried])
}

@Test func signalResponsePostponeDelaysOnlyTheNamedRequestAndCountsTheFailure() {
    var other = request()
    other.id = "r2"
    let state = SignalRequestState(requests: [request(), other], pinnedDevice: "a")
    var postponed = request()
    postponed.dueAtMS = 5_000 + 10 * minute
    postponed.failureCount = 1
    #expect(SignalResponseHandling.postpone(state, requestID: "r1", nowMS: 5_000).requests == [postponed, other])
    #expect(SignalResponseHandling.postpone(state, requestID: "none", nowMS: 5_000) == state)
}

@Test func signalResponseDocumentUsesRecordingSpanAndDropsBucketsOutsideTheSlice() {
    let document = SignalResponseHandling.document(
        request: request(),
        response: response(buckets: [SignalBucket(start: 10 * minute, end: 20 * minute), SignalBucket(start: 20 * minute, end: 30 * minute)]),
        nowMS: 99)
    #expect(document.header == SignalsHeader(prefix: "p", start: 0, end: 30 * minute, bucketMS: 600_000, requestedAt: 99))
    #expect(document.buckets.map(\.start) == [10 * minute])
}

@Test func signalNoticesWaitAfterAnEmptyFirstRoundAndWarnAfterAnEmptySecondRound() {
    let empty = merged([SignalBucket(start: 0, end: 10 * minute)])
    #expect(SignalNotices.notices(merged: empty, sources: response(hr: .empty, hrv: .empty).sources, round: 1) == [.waiting])
    #expect(SignalNotices.notices(merged: empty, sources: response(hr: .empty, hrv: .empty).sources, round: 2) == [.noHeartRate])
}

@Test func signalNoticesStayQuietWhenEarlierRoundAlreadyBroughtHeartRate() {
    let filled = merged([SignalBucket(start: 0, end: 10 * minute, hr: HeartRateSummary(mean: 70, min: nil, max: nil, n: 1))])
    #expect(SignalNotices.notices(merged: filled, sources: response(hr: .empty, hrv: .empty).sources, round: 2).isEmpty)
}

@Test func signalNoticesApplyToShortRecordingsToo() {
    let short = SignalsDocument(
        header: SignalsHeader(prefix: "p", start: 0, end: 2 * minute, bucketMS: 600_000, requestedAt: 0),
        buckets: [SignalBucket(start: 0, end: 2 * minute)])
    let empty = response(hr: .empty, hrv: .empty).sources
    #expect(SignalNotices.notices(merged: short, sources: empty, round: 1) == [.waiting])
    #expect(SignalNotices.notices(merged: short, sources: empty, round: 2) == [.noHeartRate])
}

@Test func signalNoticesDoNotAskForLocationPermissionWhenNoPlaceIsRegistered() {
    let filled = merged([SignalBucket(start: 0, end: 10 * minute, hr: HeartRateSummary(mean: 70, min: nil, max: nil, n: 1))])
    #expect(SignalNotices.notices(merged: filled, sources: response(place: .notConfigured).sources, round: 1).isEmpty)
}

@Test func signalNoticesReportNotRequestedHealthAndLocationPermissionSeparately() {
    let filled = merged([SignalBucket(start: 0, end: 10 * minute, hr: HeartRateSummary(mean: 70, min: nil, max: nil, n: 1))])
    #expect(SignalNotices.notices(merged: filled, sources: response(hr: .notRequested, hrv: .notRequested).sources, round: 1) == [.noHeartRate])
    #expect(SignalNotices.notices(merged: filled, sources: response(place: .denied).sources, round: 1) == [.locationNotAllowed])
    #expect(SignalNotices.notices(merged: filled, sources: response(place: .notDetermined).sources, round: 1) == [.locationNotAllowed])
    #expect(SignalNotices.notices(merged: filled, sources: response(place: .whenInUse).sources, round: 1).isEmpty)
}

@Test func signalStatusLabelShowsNoticesOfTheLatestThreeRecordings() {
    let states = [
        "20261001_100000": SignalStateEvent(prefix: "20261001_100000", notices: [.waiting]),
        "20261002_100000": SignalStateEvent(prefix: "20261002_100000", notices: []),
        "20261003_100000": SignalStateEvent(prefix: "20261003_100000", notices: [.noHeartRate, .locationNotAllowed]),
        "20261004_100000": SignalStateEvent(prefix: "20261004_100000", notices: [.waiting]),
    ]
    #expect(
        SignalStatusLabel.menuLines(states: states) == [
            "20261003_100000: 心拍が取れていません。Watchを着けていたか、iPhoneのヘルスケアの許可を確認してください",
            "20261003_100000: 地点が取れていません。iPhoneの位置情報の許可を確認してください",
            "20261004_100000: 心拍はまだ届いていません。30分後にもう一度取ります",
        ])
}
