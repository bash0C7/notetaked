import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func atomicWriteCreatesParentAndReplacesContent() throws {
    let directory = temporaryDirectory("atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nested/state.json")

    try AtomicFile.write(Data("one".utf8), to: url)
    try AtomicFile.write(Data("two".utf8), to: url)

    #expect(try String(contentsOf: url, encoding: .utf8) == "two")
}

@Test func atomicWriteLeavesNoTemporaryFiles() throws {
    let directory = temporaryDirectory("atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("state.json")

    for index in 0..<50 {
        try AtomicFile.write(Data("\(index)".utf8), to: url)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
}

@Test func atomicWriteFailureRemovesTemporaryFile() throws {
    let directory = temporaryDirectory("atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocked = directory.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: blocked.appendingPathComponent("inside"))

    #expect(throws: (any Error).self) {
        try AtomicFile.write(Data("y".utf8), to: blocked)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["blocked"])
}

private struct Sample: Codable, Equatable {
    var name: String
}

@Test func jsonFileRoundTripsAndReportsMissingAndBrokenFiles() throws {
    let directory = temporaryDirectory("json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("state.json")

    #expect(try JSONFile.read(Sample.self, from: url) == nil)

    try JSONFile.write(Sample(name: "山田太郎"), to: url)
    #expect(try JSONFile.read(Sample.self, from: url) == Sample(name: "山田太郎"))

    try AtomicFile.write(Data("{".utf8), to: url)
    #expect(throws: (any Error).self) {
        _ = try JSONFile.read(Sample.self, from: url)
    }
}

@Test func heartbeatWriteLeavesNoTemporaryFiles() throws {
    let directory = temporaryDirectory("heartbeat")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("process.heartbeat")

    for _ in 0..<20 {
        try Heartbeat.write(to: url)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["process.heartbeat"])
    #expect(Heartbeat.currentStatus(of: url, threshold: 15) == .alive)
}
