import Foundation
import Testing

@testable import notetaked

private let shell = URL(fileURLWithPath: "/bin/sh")

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.withLock { items.append(line) } }
    var all: [String] { lock.withLock { items } }
}

@Test func processPassesStderrLinesToTheCallerAndSucceedsOnZeroExit() async throws {
    let lines = Lines()
    try await FinalizeProcess.run(executable: shell, arguments: ["-c", "echo one >&2; echo two >&2"]) {
        lines.add($0)
    }
    #expect(lines.all == ["one", "two"])
}

@Test func processReportsTheExitStatusAndTheLastLines() async {
    do {
        try await FinalizeProcess.run(executable: shell, arguments: ["-c", "echo boom >&2; exit 3"]) { _ in }
        Issue.record("expected a failure")
    } catch let error as FinalizeProcessError {
        guard case .exited(let status, let tail) = error else {
            Issue.record("unexpected error \(error)")
            return
        }
        #expect(status == 3)
        #expect(tail == "boom")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func processIsStoppedWhenItsOutputStalls() async {
    let start = Date()
    do {
        try await FinalizeProcess.run(
            executable: shell, arguments: ["-c", "echo start >&2; sleep 30"], stallTimeout: 1
        ) { _ in }
        Issue.record("expected a stall")
    } catch let error as FinalizeProcessError {
        guard case .stalled = error else {
            Issue.record("unexpected error \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error \(error)")
    }
    #expect(Date().timeIntervalSince(start) < 15)
}

@Test func cancellingTheTaskStopsTheProcess() async {
    let start = Date()
    let task = Task {
        try await FinalizeProcess.run(
            executable: shell, arguments: ["-c", "echo start >&2; sleep 30"], stallTimeout: 600
        ) { _ in }
    }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()
    _ = try? await task.value
    #expect(Date().timeIntervalSince(start) < 15)
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// serveはstdinを`bytes.lines`で読み続ける。書き込みの来ない読み取りが同時にあっても、
/// 子の出力と終了は待たされずに届く
@Test func childOutputIsNotHeldUpByAnIdleReaderOfAnotherPipe() async throws {
    let idle = Pipe()
    let idleReader = Task {
        for try await _ in idle.fileHandleForReading.bytes.lines {}
    }
    defer {
        idleReader.cancel()
        try? idle.fileHandleForWriting.close()
    }
    try await Task.sleep(for: .milliseconds(300))

    let lines = Lines()
    let finished = Flag()
    let run = Task {
        try await FinalizeProcess.run(executable: shell, arguments: ["-c", "echo one >&2; echo two >&2"]) {
            lines.add($0)
        }
        finished.set()
    }
    for _ in 0..<80 where !finished.isSet {
        try await Task.sleep(for: .milliseconds(100))
    }
    run.cancel()
    #expect(finished.isSet)
    #expect(lines.all == ["one", "two"])
}
