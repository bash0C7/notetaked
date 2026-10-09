import Foundation
import Testing
@testable import NotetakeCore

private let minute: Int64 = 60_000
private let hour: Int64 = 3_600_000

private func ids() -> () -> String {
    var next = 0
    return {
        next += 1
        return "r\(next)"
    }
}

private func request(
    id: String = "r1", prefix: String = "p", startMS: Int64 = 0, round: Int = 1,
    createdAtMS: Int64 = 0, dueAtMS: Int64 = 0
) -> SignalRequest {
    SignalRequest(
        id: id, prefix: prefix, outputDirectory: "/out", recordingStartMS: 0, recordingEndMS: 10 * minute,
        startMS: startMS, endMS: 10 * minute, round: round, createdAtMS: createdAtMS, dueAtMS: dueAtMS,
        failureCount: 0)
}

@Test func signalPlannerMakesFirstAndSecondRoundForOneRecording() {
    let made = SignalPlanner.requests(
        prefix: "p", outputDirectory: "/out", startMS: 3 * minute, endMS: 25 * minute, nowMS: 26 * minute,
        makeID: ids())
    #expect(made.map(\.round) == [1, 2])
    #expect(made.map(\.dueAtMS) == [26 * minute, 26 * minute + 30 * minute])
    #expect(made.allSatisfy { $0.startMS == 3 * minute && $0.endMS == 25 * minute })
    #expect(made.allSatisfy { $0.outputDirectory == "/out" && $0.recordingStartMS == 3 * minute && $0.recordingEndMS == 25 * minute })
}

@Test func signalPlannerSplitsRecordingsLongerThanADayOnTheGrid() {
    let made = SignalPlanner.requests(
        prefix: "p", outputDirectory: "/out", startMS: 3 * minute, endMS: 25 * hour, nowMS: 25 * hour,
        makeID: ids())
    let firstRound = made.filter { $0.round == 1 }
    #expect(firstRound.map(\.startMS) == [3 * minute, 24 * hour])
    #expect(firstRound.map(\.endMS) == [24 * hour, 25 * hour])
    #expect(made.count == 4)
}

@Test func signalPlannerAddingFoldsTheSameRecordingSliceAndRound() {
    let state = SignalRequestState(requests: [request(id: "old")])
    let added = SignalPlanner.adding([request(id: "new"), request(id: "second", round: 2)], to: state)
    #expect(added.requests.map(\.id) == ["old", "second"])
}

@Test func signalRequestStoreRoundTripsThroughTheFileAndStartsEmpty() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("signal-requests.json")
    let store = SignalRequestStore(url: url)
    #expect(try store.load() == SignalRequestState())
    let state = SignalRequestState(requests: [request(round: 2, dueAtMS: 3 * hour)], pinnedDevice: "iphone-1")
    try store.save(state)
    #expect(try SignalRequestStore(url: url).load() == state)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"due_at_ms\":10800000"))
    #expect(text.contains("\"pinned_device\":\"iphone-1\""))
}

@Test func signalDispatchPinsTheFirstIPhoneThatAnnouncesSignal() {
    let signal = HelloMessage(device: "a", deviceName: "A", owner: "o", platform: .ios, capabilities: ["signal"])
    let other = HelloMessage(device: "b", deviceName: "B", owner: "o", platform: .ios, capabilities: ["signal"])
    let old = HelloMessage(device: "c", deviceName: "C", owner: "o", platform: .ios)
    #expect(SignalDispatch.pin(SignalRequestState(), hello: old).pinnedDevice == nil)
    let pinned = SignalDispatch.pin(SignalRequestState(), hello: signal)
    #expect(pinned.pinnedDevice == "a")
    #expect(SignalDispatch.pin(pinned, hello: other).pinnedDevice == "a")
}

@Test func signalDispatchRecordsThePinnedDeviceNameAndUpdatesItWhenItChanges() {
    let signal = HelloMessage(device: "a", deviceName: "A", owner: "o", platform: .ios, capabilities: ["signal"])
    let pinned = SignalDispatch.pin(SignalRequestState(), hello: signal)
    #expect(pinned.pinnedDeviceName == "A")
    let legacy = SignalRequestState(requests: [], pinnedDevice: "a")
    #expect(SignalDispatch.pin(legacy, hello: signal).pinnedDeviceName == "A")
    let renamed = HelloMessage(device: "a", deviceName: "A2", owner: "o", platform: .ios, capabilities: ["signal"])
    #expect(SignalDispatch.pin(pinned, hello: renamed).pinnedDeviceName == "A2")
    #expect(SignalDispatch.pin(pinned, hello: signal) == pinned)
}

@Test func signalDispatchMovesThePinToAnIPhoneWithTheSameNameAndAnotherID() {
    let pinned = SignalDispatch.pin(
        SignalRequestState(requests: [request()]),
        hello: HelloMessage(device: "a", deviceName: "A", owner: "o", platform: .ios, capabilities: ["signal"]))
    let reinstalled = HelloMessage(device: "a2", deviceName: "A", owner: "o", platform: .ios, capabilities: ["signal"])
    let moved = SignalDispatch.pin(pinned, hello: reinstalled)
    #expect(moved.pinnedDevice == "a2")
    #expect(moved.pinnedDeviceName == "A")
    #expect(moved.requests == pinned.requests)
}

@Test func signalDispatchKeepsThePinAgainstOtherNamesAndPeersWithoutSignal() {
    let pinned = SignalDispatch.pin(
        SignalRequestState(),
        hello: HelloMessage(device: "a", deviceName: "A", owner: "o", platform: .ios, capabilities: ["signal"]))
    let other = HelloMessage(device: "b", deviceName: "B", owner: "o", platform: .ios, capabilities: ["signal"])
    let sameNameWithoutSignal = HelloMessage(device: "c", deviceName: "A", owner: "o", platform: .ios)
    #expect(SignalDispatch.pin(pinned, hello: other) == pinned)
    #expect(SignalDispatch.pin(pinned, hello: sameNameWithoutSignal) == pinned)
}

@Test func signalRequestStateReadsAFileWithoutThePinnedDeviceName() throws {
    let json = "{\"pinned_device\":\"a\",\"requests\":[]}"
    let state = try JSONDecoder().decode(SignalRequestState.self, from: Data(json.utf8))
    #expect(state == SignalRequestState(requests: [], pinnedDevice: "a", pinnedDeviceName: nil))
}

@Test func signalDispatchExpiresRequestsOlderThanSevenDays() {
    let state = SignalRequestState(requests: [request(id: "old", createdAtMS: 0), request(id: "fresh", createdAtMS: 2 * hour)])
    let result = SignalDispatch.expire(state, nowMS: 7 * 24 * hour + 1)
    #expect(result.expired.map(\.id) == ["old"])
    #expect(result.state.requests.map(\.id) == ["fresh"])
}

@Test func signalDispatchSendsOnlyToThePinnedConnectedIPhoneOneAtATime() {
    let state = SignalRequestState(
        requests: [request(id: "later", dueAtMS: 5), request(id: "sooner", dueAtMS: 1), request(id: "future", dueAtMS: 100)],
        pinnedDevice: "a")
    let pinnedPeer = [SignalPeer(device: "a", supportsSignal: true)]
    #expect(SignalDispatch.decide(state: state, peers: pinnedPeer, inFlight: false, nowMS: 10)?.id == "sooner")
    #expect(SignalDispatch.decide(state: state, peers: pinnedPeer, inFlight: true, nowMS: 10) == nil)
    #expect(SignalDispatch.decide(state: state, peers: [SignalPeer(device: "b", supportsSignal: true)], inFlight: false, nowMS: 10) == nil)
    #expect(SignalDispatch.decide(state: state, peers: [SignalPeer(device: "a", supportsSignal: false)], inFlight: false, nowMS: 10) == nil)
    var unpinned = state
    unpinned.pinnedDevice = nil
    #expect(SignalDispatch.decide(state: unpinned, peers: pinnedPeer, inFlight: false, nowMS: 10) == nil)
    #expect(SignalDispatch.decide(state: state, peers: pinnedPeer, inFlight: false, nowMS: 0) == nil)
}
