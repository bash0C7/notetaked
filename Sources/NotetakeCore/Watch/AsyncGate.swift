import Foundation

/// 到着順に1つずつ通す非同期の排他。actorは`await`の間に別の呼び出しが入る（再入する）ので、
/// 処理の途中に`await`を挟んでも順序と排他を守りたい操作（`WatchRelay`の小片の処理・保留の流し・stream の終了）を
/// 1本の連鎖にするために使う。再入して取ってはならない（待ち続ける）
public final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// 取るのを待っている数（テストで到着順を決めるため）
    public var waiterCount: Int { lock.withLock { waiters.count } }

    public func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate: Bool = lock.withLock {
                if isHeld {
                    waiters.append(continuation)
                    return false
                }
                isHeld = true
                return true
            }
            if immediate { continuation.resume() }
        }
    }

    public func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                isHeld = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }

    /// 呼び出し元のactorの上で`body`を走らせる（actorの中から呼んでも`self`を触れる）
    public func run<T: Sendable>(isolation: isolated (any Actor)? = #isolation, _ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }
}
