import Foundation

public protocol WatchChunkFeeding: Sendable {
    func handle(_ entry: WatchInboxEntry) async
}

/// Watchの小片の受信を1本の列にする。`didReceive`ごとの`Task`とactorの再入で順序が崩れないよう、
/// `AsyncStream`へ積み、1本の`Task`が順に`feeder.handle`する
public actor WatchIntakeQueue {
    /// 列に載っているか処理中のid。`submit`はどのthreadからも呼ばれるのでlockで守る
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var count: Int { lock.withLock { ids.count } }

        func insert(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }

        func finish(_ id: String) {
            let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
                ids.remove(id)
                guard ids.isEmpty else { return [] }
                defer { waiters = [] }
                return waiters
            }
            for waiter in resumed { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let immediate: Bool = lock.withLock {
                    if ids.isEmpty { return true }
                    waiters.append(continuation)
                    return false
                }
                if immediate { continuation.resume() }
            }
        }
    }

    private let continuation: AsyncStream<WatchInboxEntry>.Continuation
    private nonisolated let pending: Pending

    public init(feeder: any WatchChunkFeeding) {
        let (stream, continuation) = AsyncStream<WatchInboxEntry>.makeStream()
        let pending = Pending()
        self.continuation = continuation
        self.pending = pending
        Task {
            for await entry in stream {
                await feeder.handle(entry)
                pending.finish(entry.id)
            }
        }
    }

    deinit { continuation.finish() }

    /// 1つのthreadから続けて呼んだ順に処理する。同じidが列に載っているか処理中なら捨てる
    public nonisolated func submit(_ entry: WatchInboxEntry) {
        guard pending.insert(entry.id) else { return }
        continuation.yield(entry)
    }

    /// 今までにsubmitしたものを全部処理し終えるまで待つ
    public func drain() async { await pending.wait() }

    /// submitされてまだ処理を終えていない件数
    public nonisolated var backlog: Int { pending.count }
}
