import Foundation
import Testing
@testable import NotetakeCore

private let minute: Int64 = 60_000

private struct FakeHealthError: Error {}

private struct FakeHealth: HealthSampleReading {
    var notRequested = false
    var heartRateResult: Result<[HeartRateSample], FakeHealthError> = .success([])
    var hrvResult: Result<[HRVSample], FakeHealthError> = .success([])

    func heartRates(startMS: Int64, endMS: Int64) async throws -> [HeartRateSample] { try heartRateResult.get() }
    func hrv(startMS: Int64, endMS: Int64) async throws -> [HRVSample] { try hrvResult.get() }
    func needsAuthorizationRequest() async -> Bool { notRequested }
}

private let request = SignalRequestMessage(id: "r1", prefix: "p", startMS: 0, endMS: 20 * minute, bucketMS: 600_000, pending: 1)

@Test func signalResponderAggregatesSamplesAndStaysIntoBuckets() async {
    let response = await SignalResponder.respond(
        to: request,
        health: FakeHealth(heartRateResult: .success([HeartRateSample(at: minute, bpm: 72)])),
        stays: [PlaceStay(start: 0, end: nil, label: "自宅")], placeStatus: .always)
    #expect(response.id == "r1")
    #expect(response.sources == SignalSources(hr: .ok, hrv: .empty, place: .always))
    #expect(response.buckets.map(\.start) == [0, 10 * minute])
    #expect(response.buckets[0].hr == HeartRateSummary(mean: 72, min: nil, max: nil, n: 1))
    #expect(response.buckets.allSatisfy { $0.place == "自宅" })
}

@Test func signalResponderReportsNotRequestedWithoutReading() async {
    let response = await SignalResponder.respond(
        to: request, health: FakeHealth(notRequested: true, heartRateResult: .failure(FakeHealthError())),
        stays: [], placeStatus: .notDetermined)
    #expect(response.sources == SignalSources(hr: .notRequested, hrv: .notRequested, place: .notDetermined))
    #expect(response.buckets.allSatisfy { $0.hr == nil && $0.place == nil })
}

@Test func signalResponderReportsUnavailableWhenHealthKitFails() async {
    let response = await SignalResponder.respond(
        to: request, health: FakeHealth(heartRateResult: .failure(FakeHealthError())), stays: [], placeStatus: .always)
    #expect(response.sources.hr == .unavailable)
    #expect(response.sources.hrv == .empty)
}
