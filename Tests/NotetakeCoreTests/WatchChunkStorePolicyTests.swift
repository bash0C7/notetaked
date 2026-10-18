import Foundation
import Testing
@testable import NotetakeCore

private func metadata(session: String = "1000", index: Int = 0, startAtMS: Int64 = 1_000) -> WatchChunkMetadata {
    WatchChunkMetadata(
        session: session, index: index, startAtMS: startAtMS, sampleRate: 48_000,
        device: "dev", deviceName: "Watch", owner: "私")
}

private func sidecar(
    complete: Bool, session: String = "1000", index: Int = 0, durationMS: Int64? = 20_000
) -> WatchChunkSidecar {
    WatchChunkSidecar(
        complete: complete, session: session, index: index, openedAtMS: 1_000, durationMS: durationMS,
        metadataJSON: (try? metadata(session: session, index: index).encodedJSON()) ?? "")
}

private func stored(
    _ name: String, _ sidecar: WatchChunkSidecar?, bytes: Int64 = 1_000
) -> StoredChunk {
    StoredChunk(fileName: name, sidecar: sidecar, sizeBytes: bytes)
}

@Test func activeSessionIsNeverResentOrInspected() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("1000-0.m4a", sidecar(complete: true, index: 0)),
            stored("1000-1.m4a", sidecar(complete: false, index: 1)),
            stored("1000-2.m4a", sidecar(complete: false, index: 2)),
        ],
        outstanding: [], activeSession: "1000")
    #expect(plan.resend.isEmpty)
    #expect(plan.inspect.isEmpty)
    #expect(plan.drop.isEmpty)
}

@Test func activeSessionLatestWithoutSidecarIsLeftAlone() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("1000-0.m4a", nil),
            stored("1000-1.m4a", sidecar(complete: true, index: 1)),
            stored("1000-2.m4a", nil),
        ],
        outstanding: [], activeSession: "1000")
    // 最大のindexの2は書き込みの途中でありうるので何もしない。0は開く前に落ちたものとして消す
    #expect(plan.drop == ["1000-0.m4a"])
}

@Test func otherSessionsAreHandledWhileRecording() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("900-0.m4a", sidecar(complete: true, session: "900", index: 0)),
            stored("1000-0.m4a", sidecar(complete: true, index: 0)),
        ],
        outstanding: [], activeSession: "1000")
    #expect(plan.resend == ["900-0.m4a"])
}

@Test func missingSidecarIsDropped() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [stored("900-0.m4a", nil)], outstanding: [], activeSession: nil)
    #expect(plan.drop == ["900-0.m4a"])
    #expect(plan.resend.isEmpty)
}

@Test func incompleteChunkIsInspected() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [stored("900-0.m4a", sidecar(complete: false, session: "900"))],
        outstanding: [], activeSession: nil)
    #expect(plan.inspect == ["900-0.m4a"])
}

@Test func completedNotOutstandingIsResent() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [stored("900-0.m4a", sidecar(complete: true, session: "900"))],
        outstanding: [], activeSession: nil)
    #expect(plan.resend == ["900-0.m4a"])
}

@Test func completedOutstandingIsLeftAlone() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [stored("900-0.m4a", sidecar(complete: true, session: "900"))],
        outstanding: ["900-0.m4a"], activeSession: nil)
    #expect(plan == ChunkStorePlan(resend: [], inspect: [], drop: [], cancelBeforeDrop: [], droppedDurationMS: 0))
}

private let mb: Int64 = 1024 * 1024

@Test func overCapacityDropsOldestCompletedFirst() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("1-0.m4a", sidecar(complete: true, session: "1", index: 0, durationMS: 21_000), bytes: 80 * mb),
            stored("2-0.m4a", sidecar(complete: true, session: "2", index: 0), bytes: 80 * mb),
            stored("3-0.m4a", sidecar(complete: true, session: "3", index: 0), bytes: 80 * mb),
        ],
        outstanding: ["1-0.m4a", "2-0.m4a", "3-0.m4a"], activeSession: nil)
    #expect(plan.drop == ["1-0.m4a"])
    #expect(plan.droppedDurationMS == 21_000)
}

@Test func overCapacityCancelsAnOutstandingTransferFirst() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("1-0.m4a", sidecar(complete: true, session: "1", index: 0), bytes: 120 * mb),
            stored("2-0.m4a", sidecar(complete: true, session: "2", index: 0), bytes: 120 * mb),
        ],
        outstanding: ["1-0.m4a"], activeSession: nil)
    #expect(plan.drop == ["1-0.m4a"])
    #expect(plan.cancelBeforeDrop == ["1-0.m4a"])
}

@Test func overCapacityDoesNotCancelANonOutstandingOne() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("1-0.m4a", sidecar(complete: true, session: "1", index: 0), bytes: 120 * mb),
            stored("2-0.m4a", sidecar(complete: true, session: "2", index: 0), bytes: 120 * mb),
        ],
        outstanding: [], activeSession: nil)
    #expect(plan.drop == ["1-0.m4a"])
    #expect(plan.cancelBeforeDrop.isEmpty)
    #expect(plan.resend == ["2-0.m4a"])
}

@Test func sessionsAreOrderedNumerically() {
    let plan = WatchChunkStorePolicy.plan(
        stored: [
            stored("1000-0.m4a", sidecar(complete: true, session: "1000", index: 0), bytes: 120 * mb),
            stored("999-0.m4a", sidecar(complete: true, session: "999", index: 0), bytes: 120 * mb),
        ],
        outstanding: ["1000-0.m4a", "999-0.m4a"], activeSession: nil)
    #expect(plan.drop == ["999-0.m4a"])
}

@Test func sidecarRoundTrips() throws {
    let original = sidecar(complete: false, session: "900", index: 3, durationMS: nil)
    let data = try JSONEncoder().encode(original)
    #expect(WatchChunkSidecar.decode(data) == original)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["opened_at_ms"] as? Int == 1_000)
    #expect(object["metadata_json"] is String)
    #expect(object["complete"] as? Bool == false)
}

@Test func legacyMetadataSidecarDecodesAsComplete() throws {
    let legacy = metadata(session: "900", index: 2, startAtMS: 4_000)
    let data = try JSONSerialization.data(withJSONObject: legacy.metadata)
    let decoded = try #require(WatchChunkSidecar.decode(data))
    #expect(decoded.complete)
    #expect(decoded.session == "900")
    #expect(decoded.index == 2)
    #expect(decoded.openedAtMS == 4_000)
    #expect(decoded.metadata == legacy)
}

@Test func brokenSidecarDecodesAsNil() {
    #expect(WatchChunkSidecar.decode(Data("not json".utf8)) == nil)
    #expect(WatchChunkSidecar.decode(Data("{\"foo\":1}".utf8)) == nil)
}

@Test func inspectionCompletesWithTheFrameDuration() throws {
    let open = sidecar(complete: false, session: "900", index: 1, durationMS: nil)
    let done = try #require(open.completedByInspection(frames: 96_000))
    #expect(done.complete)
    #expect(done.durationMS == 2_000)
    let meta = try #require(done.metadata)
    #expect(meta.isFinal == nil)
    #expect(meta.session == "900")
    #expect(meta.sampleRate == 48_000)
    #expect(meta.device == "dev")
    #expect(meta.owner == "私")
}

@Test func inspectionWithNoFramesIsNil() {
    #expect(sidecar(complete: false).completedByInspection(frames: 0) == nil)
}

@Test func recoverKeepsTheDrainingSessionActive() {
    #expect(WatchChunkStorePolicy.activeSession(current: "2", draining: "1") == "2")
    #expect(WatchChunkStorePolicy.activeSession(current: nil, draining: "1") == "1")
    #expect(WatchChunkStorePolicy.activeSession(current: nil, draining: nil) == nil)
}
