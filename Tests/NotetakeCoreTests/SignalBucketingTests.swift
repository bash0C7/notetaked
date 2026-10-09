import Foundation
import Testing
@testable import NotetakeCore

private let minute: Int64 = 60_000

@Test func signalBucketingAlignsToTenMinuteGridAndMarksPartialEnds() {
    let buckets = SignalBucketing.buckets(
        startMS: 3 * minute, endMS: 25 * minute, heartRates: [], hrv: [], stays: [])
    #expect(buckets.map(\.start) == [3 * minute, 10 * minute, 20 * minute])
    #expect(buckets.map(\.end) == [10 * minute, 20 * minute, 25 * minute])
    #expect(buckets.map(\.partial) == [true, false, true])
}

@Test func signalBucketingConsecutiveRecordingsNeitherOverlapNorLeaveGaps() {
    let first = SignalBucketing.buckets(startMS: 2 * minute, endMS: 15 * minute, heartRates: [], hrv: [], stays: [])
    let second = SignalBucketing.buckets(startMS: 15 * minute, endMS: 31 * minute, heartRates: [], hrv: [], stays: [])
    let all = first + second
    for (previous, next) in zip(all, all.dropFirst()) {
        #expect(previous.end == next.start)
    }
    #expect(all.first?.start == 2 * minute)
    #expect(all.last?.end == 31 * minute)
}

@Test func signalBucketingSummarizesHeartRateAndOmitsMinMaxBelowThreeSamples() {
    let buckets = SignalBucketing.buckets(
        startMS: 0, endMS: 20 * minute,
        heartRates: [
            HeartRateSample(at: 1 * minute, bpm: 72),
            HeartRateSample(at: 11 * minute, bpm: 64),
            HeartRateSample(at: 12 * minute, bpm: 70),
            HeartRateSample(at: 13 * minute, bpm: 88),
        ],
        hrv: [HRVSample(at: 14 * minute, sdnnMS: 45.24)], stays: [])
    #expect(buckets[0].hr == HeartRateSummary(mean: 72, min: nil, max: nil, n: 1))
    #expect(buckets[0].hrv == nil)
    #expect(buckets[1].hr == HeartRateSummary(mean: 74, min: 64, max: 88, n: 3))
    #expect(buckets[1].hrv == HRVSummary(meanSDNNMS: 45.2, n: 1))
}

@Test func signalBucketingDropsSamplesOutsideTheRange() {
    let buckets = SignalBucketing.buckets(
        startMS: 10 * minute, endMS: 20 * minute,
        heartRates: [HeartRateSample(at: 9 * minute, bpm: 60), HeartRateSample(at: 20 * minute, bpm: 61)],
        hrv: [], stays: [])
    #expect(buckets.count == 1)
    #expect(buckets[0].hr == nil)
}

@Test func signalBucketingPicksLongestOverlappingStayAndRunsOpenStayToTheEnd() {
    let buckets = SignalBucketing.buckets(
        startMS: 0, endMS: 20 * minute, heartRates: [], hrv: [],
        stays: [
            PlaceStay(start: 0, end: 3 * minute, label: "自宅"),
            PlaceStay(start: 3 * minute, end: nil, label: "オフィス"),
        ])
    #expect(buckets[0].place == "オフィス")
    #expect(buckets[1].place == "オフィス")
}

@Test func signalBucketingLeavesPlaceEmptyWhenNoStayOverlaps() {
    let buckets = SignalBucketing.buckets(
        startMS: 0, endMS: 10 * minute, heartRates: [], hrv: [],
        stays: [PlaceStay(start: 20 * minute, end: 30 * minute, label: "自宅")])
    #expect(buckets[0].place == nil)
}

@Test func signalBucketingOverlayKeepsPreviousValuesWhenIncomingIsEmpty() {
    let previous = [SignalBucket(start: 0, end: 10 * minute, place: "自宅", hr: HeartRateSummary(mean: 72, min: nil, max: nil, n: 1))]
    let incoming = [SignalBucket(start: 0, end: 10 * minute)]
    let merged = SignalBucketing.overlay(existing: previous, incoming: incoming)
    #expect(merged == previous)
}

@Test func signalBucketingOverlayReplacesWithIncomingDataAndKeepsUntouchedBuckets() {
    let previous = [
        SignalBucket(start: 0, end: 10 * minute, hr: HeartRateSummary(mean: 72, min: nil, max: nil, n: 1)),
        SignalBucket(start: 10 * minute, end: 20 * minute, place: "自宅"),
    ]
    let incoming = [SignalBucket(start: 0, end: 10 * minute, hrv: HRVSummary(meanSDNNMS: 40, n: 1))]
    let merged = SignalBucketing.overlay(existing: previous, incoming: incoming)
    #expect(merged[0].hr == HeartRateSummary(mean: 72, min: nil, max: nil, n: 1))
    #expect(merged[0].hrv == HRVSummary(meanSDNNMS: 40, n: 1))
    #expect(merged[1].place == "自宅")
}

@Test func signalBucketingClipDropsBucketsOutsideTheRange() {
    let buckets = [
        SignalBucket(start: 0, end: 10 * minute),
        SignalBucket(start: 10 * minute, end: 20 * minute),
        SignalBucket(start: 20 * minute, end: 30 * minute),
    ]
    #expect(SignalBucketing.clip(buckets, startMS: 10 * minute, endMS: 20 * minute).map(\.start) == [10 * minute])
}

@Test func signalBucketEncodingWritesNullForMissingMeasurementsOnly() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(SignalBucket(start: 0, end: 600_000)), as: UTF8.self)
    #expect(text == "{\"end\":600000,\"hr\":null,\"hrv\":null,\"start\":0}")
    let decoded = try JSONDecoder().decode(SignalBucket.self, from: Data("{\"start\":0,\"end\":600000}".utf8))
    #expect(decoded == SignalBucket(start: 0, end: 600_000))
}
