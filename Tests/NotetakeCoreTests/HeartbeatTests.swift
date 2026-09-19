// Tests/NotetakeCoreTests/HeartbeatTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func statusIsAliveWithinThreshold() {
    let now = Date()
    let lastBeat = now.addingTimeInterval(-10)
    #expect(Heartbeat.status(lastBeat: lastBeat, now: now, threshold: 15) == .alive)
}

@Test func statusIsStaleBeyondThreshold() {
    let now = Date()
    let lastBeat = now.addingTimeInterval(-16)
    #expect(Heartbeat.status(lastBeat: lastBeat, now: now, threshold: 15) == .stale)
}

@Test func statusIsStaleWhenNoBeatRecorded() {
    #expect(Heartbeat.status(lastBeat: nil, now: Date(), threshold: 15) == .stale)
}

@Test func writeThenCurrentStatusIsAlive() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heartbeat-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("process.heartbeat")
    try Heartbeat.write(to: url)
    #expect(Heartbeat.currentStatus(of: url, threshold: 15) == .alive)
}

@Test func currentStatusIsStaleWhenFileMissing() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).heartbeat")
    #expect(Heartbeat.currentStatus(of: missing, threshold: 15) == .stale)
}

@Test func statePathsAreDistinct() {
    let paths = [
        CaptureStatePaths.processHeartbeatURL,
        CaptureStatePaths.captureHeartbeatURL,
        CaptureStatePaths.captureCommandURL,
        CaptureStatePaths.captureEventURL,
        CaptureStatePaths.currentSessionMarkerURL,
    ]
    #expect(Set(paths.map(\.lastPathComponent)).count == paths.count)
    #expect(CaptureStatePaths.processHeartbeatURL.path.contains("Notetake/state"))
}
