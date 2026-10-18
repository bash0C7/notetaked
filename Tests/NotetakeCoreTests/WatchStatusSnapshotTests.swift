import Foundation
import Testing
@testable import NotetakeCore

private func fullSnapshot() -> WatchStatusSnapshot {
    WatchStatusSnapshot(
        device: "watch-abc", deviceName: "小芝のApple Watch", session: "s1", state: .halted,
        haltReason: .routeChanged, haltDetail: "detail", stateAtMS: 100, lastChunkReceivedAtMS: 90,
        lastChunkIndex: 4, missingChunkCount: 1,
        levels: [WatchChunkLevel(index: 4, startAtMS: 80, durationMS: 20_000, maxDBFS: -10, meanDBFS: -30)],
        batteryLevel: 0.5, batteryAtMS: 95, lastText: "こんにちは", lastTextAtMS: 99,
        inboxPendingCount: 2, updatedAtMS: 110)
}

@Test func snapshotRoundTripsWithAllFields() throws {
    let snapshot = fullSnapshot()
    #expect(try WatchStatusSnapshot.decode(json: snapshot.encodedJSON()) == snapshot)
}

@Test func minimalSnapshotOmitsNilFields() throws {
    let snapshot = WatchStatusSnapshot(device: "d", deviceName: "n", updatedAtMS: 5)
    let object = try JSONSerialization.jsonObject(with: Data(snapshot.encodedJSON().utf8)) as? [String: Any]
    #expect(Set(object?.keys.map { $0 } ?? []) == [
        "device", "device_name", "state", "missing_chunk_count", "levels", "inbox_pending_count",
        "updated_at_ms",
    ])
}

@Test func unknownStateDecodesAsUnknown() throws {
    let json = #"{"device":"d","device_name":"n","state":"future","missing_chunk_count":0,"levels":[],"inbox_pending_count":0,"updated_at_ms":1}"#
    #expect(try WatchStatusSnapshot.decode(json: json).state == .unknown)
}

@Test func unknownHaltReasonDecodesAsNil() throws {
    let json = #"{"device":"d","device_name":"n","state":"halted","halt_reason":"future","missing_chunk_count":0,"levels":[],"inbox_pending_count":0,"updated_at_ms":1}"#
    let snapshot = try WatchStatusSnapshot.decode(json: json)
    #expect(snapshot.haltReason == nil)
    #expect(snapshot.state == .halted)
}

@Test func levelKeysAreSnakeCase() throws {
    let json = try fullSnapshot().encodedJSON()
    #expect(json.contains("\"start_at_ms\""))
    #expect(json.contains("\"max_dbfs\""))
    #expect(json.contains("\"mean_dbfs\""))
    #expect(json.contains("\"duration_ms\""))
}
