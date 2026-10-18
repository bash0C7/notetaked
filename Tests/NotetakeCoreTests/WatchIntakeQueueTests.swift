import Foundation
import Testing
@testable import NotetakeCore

private func entry(_ id: String) -> WatchInboxEntry {
    WatchInboxEntry(id: id, metadataJSON: "{}", receivedAtMS: 0, attempts: 0)
}

/// 受けたidを記録し、間で`Task.yield()`する代役。`gate`を閉じておくと最初の1件で止まる
private final class RecordingFeeder: WatchChunkFeeding, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var running = 0
    private var maxRunning = 0
    private var gateOpen: Bool

    init(gateOpen: Bool = true) { self.gateOpen = gateOpen }

    var handledIDs: [String] { lock.withLock { ids } }
    var maxConcurrent: Int { lock.withLock { maxRunning } }
    func openGate() { lock.withLock { gateOpen = true } }

    func handle(_ entry: WatchInboxEntry) async {
        lock.withLock {
            running += 1
            maxRunning = max(maxRunning, running)
        }
        await Task.yield()
        while !lock.withLock({ gateOpen }) { await Task.yield() }
        lock.withLock {
            ids.append(entry.id)
            running -= 1
        }
    }
}

@Test func entriesAreHandledInSubmitOrder() async {
    let feeder = RecordingFeeder()
    let queue = WatchIntakeQueue(feeder: feeder)
    let expected = (0..<10).map { "e\($0)" }
    await Task { for id in expected { queue.submit(entry(id)) } }.value
    await queue.drain()
    #expect(feeder.handledIDs == expected)
}

@Test func handlingIsNeverConcurrent() async {
    let feeder = RecordingFeeder()
    let queue = WatchIntakeQueue(feeder: feeder)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<10 {
            group.addTask { queue.submit(entry("e\(index)")) }
        }
    }
    await queue.drain()
    #expect(feeder.handledIDs.count == 10)
    #expect(feeder.maxConcurrent == 1)
}

@Test func duplicateIdWhileQueuedIsHandledOnce() async {
    let feeder = RecordingFeeder(gateOpen: false)
    let queue = WatchIntakeQueue(feeder: feeder)
    queue.submit(entry("a"))
    queue.submit(entry("a"))
    queue.submit(entry("a"))
    #expect(queue.backlog == 1)
    feeder.openGate()
    await queue.drain()
    #expect(feeder.handledIDs == ["a"])
}

@Test func sameIdCanBeResubmittedAfterHandled() async {
    let feeder = RecordingFeeder()
    let queue = WatchIntakeQueue(feeder: feeder)
    queue.submit(entry("a"))
    await queue.drain()
    queue.submit(entry("a"))
    await queue.drain()
    #expect(feeder.handledIDs == ["a", "a"])
}

@Test func backlogCountsUnhandledEntries() async {
    let feeder = RecordingFeeder(gateOpen: false)
    let queue = WatchIntakeQueue(feeder: feeder)
    for id in ["a", "b", "c"] { queue.submit(entry(id)) }
    #expect(queue.backlog == 3)
    feeder.openGate()
    await queue.drain()
    #expect(queue.backlog == 0)
}

@Test func drainWaitsForEverything() async {
    let feeder = RecordingFeeder()
    let queue = WatchIntakeQueue(feeder: feeder)
    for index in 0..<20 { queue.submit(entry("e\(index)")) }
    await queue.drain()
    #expect(feeder.handledIDs.count == 20)
}

@Test func drainWithNothingSubmittedReturns() async {
    let queue = WatchIntakeQueue(feeder: RecordingFeeder())
    await queue.drain()
    #expect(queue.backlog == 0)
}
