import Foundation
import Testing
@testable import NotetakeCore

@Test func sessionDirectoryIsUnderCaptureNamespace() {
    let base = URL(fileURLWithPath: "/tmp")
    let dir = CaptureSessionPaths.sessionDirectory(prefix: "2026-09-19_120000", baseTemporaryDirectory: base)
    #expect(dir.path == "/tmp/notetake-capture/2026-09-19_120000")
}

@Test func rawAndCheckpointFileURLsAreDistinctPerSource() {
    let dir = URL(fileURLWithPath: "/tmp/notetake-capture/session")
    #expect(CaptureSessionPaths.rawFileURL(sessionDirectory: dir, source: "mic").lastPathComponent == "mic.raw")
    #expect(CaptureSessionPaths.checkpointFileURL(sessionDirectory: dir, source: "mic").lastPathComponent == "mic.checkpoint")
    #expect(CaptureSessionPaths.rawFileURL(sessionDirectory: dir, source: "system").lastPathComponent == "system.raw")
}

@Test func loadReturnsEmptyWhenFileMissing() {
    let missing = URL(fileURLWithPath: "/tmp/notetake-capture-tests-\(UUID().uuidString)/none.checkpoint")
    #expect(CaptureCheckpoint.load(from: missing) == CaptureCheckpoint())
}

@Test func saveThenLoadRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("mic.checkpoint")
    let checkpoint = CaptureCheckpoint(offsets: ["mic": 4096])
    try checkpoint.save(to: fileURL)
    #expect(CaptureCheckpoint.load(from: fileURL) == checkpoint)
}

@Test func saveOverwritesAtomically() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("mic.checkpoint")
    try CaptureCheckpoint(offsets: ["mic": 100]).save(to: fileURL)
    try CaptureCheckpoint(offsets: ["mic": 200]).save(to: fileURL)
    #expect(CaptureCheckpoint.load(from: fileURL).offsets["mic"] == 200)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(leftovers == ["mic.checkpoint"])
}
