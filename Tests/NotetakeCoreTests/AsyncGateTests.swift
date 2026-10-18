import Foundation
import Testing
@testable import NotetakeCore

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maxRunning = 0
    private(set) var order: [Int] = []

    func enter() { lock.withLock { running += 1; maxRunning = max(maxRunning, running) } }
    func leave(_ id: Int) { lock.withLock { running -= 1; order.append(id) } }
}

@Test func gateNeverRunsTwoBodiesAtOnce() async {
    let gate = AsyncGate()
    let probe = Probe()
    await withTaskGroup(of: Void.self) { group in
        for id in 0..<20 {
            group.addTask {
                await gate.run {
                    probe.enter()
                    await Task.yield()
                    await Task.yield()
                    probe.leave(id)
                }
            }
        }
    }
    #expect(probe.order.count == 20)
    #expect(probe.maxRunning == 1)
}

@Test func gateServesWaitersInArrivalOrder() async {
    let gate = AsyncGate()
    let probe = Probe()
    // 先頭が取っている間に、順に待ちへ入れる
    await gate.acquire()
    var tasks: [Task<Void, Never>] = []
    for id in 0..<5 {
        tasks.append(Task {
            await gate.run { probe.enter(); probe.leave(id) }
        })
        // 待ちに入るまで譲る
        for _ in 0..<20 { await Task.yield() }
    }
    gate.release()
    for task in tasks { await task.value }
    #expect(probe.order == [0, 1, 2, 3, 4])
}

@Test func gateReturnsTheBodyResult() async {
    let gate = AsyncGate()
    let value = await gate.run { 42 }
    #expect(value == 42)
    // 戻った後は再び取れる
    #expect(await gate.run { 1 } == 1)
}
