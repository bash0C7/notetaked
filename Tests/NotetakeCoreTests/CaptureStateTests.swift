import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func desiredStateUsesSnakeCaseKeys() throws {
    let desired = CaptureDesiredState(
        recording: .init(prefix: "2026-10-03_100000", directory: "/tmp/notetake-capture/2026-10-03_100000"),
        sources: [.mic, .system], pinnedInputUID: "external")
    let text = String(decoding: try JSONEncoder().encode(desired), as: UTF8.self)
    #expect(text.contains("\"pinned_input_uid\":\"external\""))
    #expect(try JSONDecoder().decode(CaptureDesiredState.self, from: Data(text.utf8)) == desired)
    #expect(
        try JSONDecoder().decode(CaptureDesiredState.self, from: Data(#"{"sources":[]}"#.utf8)) == .stopped)
}

@Test func actualStateUsesSnakeCaseKeys() throws {
    let actual = CaptureActualState(
        pid: 42, prefix: "p",
        sources: [
            .init(
                source: .mic, state: .recording,
                input: InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false),
                fellBackFromPinned: true, lastError: "書けません")
        ],
        updated: 1)
    let text = String(decoding: try JSONEncoder().encode(actual), as: UTF8.self)
    #expect(text.contains("\"fell_back_from_pinned\":true"))
    #expect(text.contains("\"last_error\":\"書けません\""))
    #expect(try JSONDecoder().decode(CaptureActualState.self, from: Data(text.utf8)) == actual)
}

@Test func desiredStateWatcherReportsOnlyChanges() throws {
    let directory = temporaryDirectory("desired")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("capture-desired.json")
    var watcher = DesiredStateWatcher(url: url)

    #expect(watcher.poll() == .changed(.stopped))
    #expect(watcher.poll() == nil)

    let recording = CaptureDesiredState(
        recording: .init(prefix: "a", directory: "/tmp/a"), sources: [.mic], pinnedInputUID: nil)
    try JSONFile.write(recording, to: url)
    #expect(watcher.poll() == .changed(recording))
    #expect(watcher.poll() == nil)

    try AtomicFile.write(Data("not json".utf8), to: url)
    guard case .unreadable = watcher.poll() else {
        Issue.record("broken desired state must be reported as unreadable")
        return
    }

    try FileManager.default.removeItem(at: url)
    #expect(watcher.poll() == .changed(.stopped))
}

@Test func desiredStateWatcherReportsAnUnreadableFileOnceInsteadOfStopping() throws {
    let directory = temporaryDirectory("desired")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("capture-desired.json")
    var watcher = DesiredStateWatcher(url: url)
    #expect(watcher.poll() == .changed(.stopped))

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    guard case .unreadable = watcher.poll() else {
        Issue.record("a stat failure other than a missing file must not be read as stopped")
        return
    }
    #expect(watcher.poll() == nil)
}
