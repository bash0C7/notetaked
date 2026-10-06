import Foundation
import NotetakeCore

enum FinalizeProcessError: Error, CustomStringConvertible {
    case exited(status: Int32, stderrTail: String)
    case stalled(after: TimeInterval)

    var description: String {
        switch self {
        case .exited(let status, let tail):
            return "finalizeが異常終了しました（status \(status)）: \(tail)"
        case .stalled(let seconds):
            return "finalizeの進捗が\(Int(seconds))秒途絶えたため止めました"
        }
    }
}

/// `notetaked finalize`を子processとして走らせる。stderrの行を`onLine`へ渡し、最後の出力から
/// `stallTimeout`を過ぎたら止めて失敗にする。`qualityOfService`は`.utility`で、ライブの文字起こしを優先させる
enum FinalizeProcess {
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var tail: [String] = []
        private var stalled = false

        func touch(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            last = Date()
            tail.append(line)
            if tail.count > 5 { tail.removeFirst() }
        }

        var lastProgress: Date {
            lock.lock()
            defer { lock.unlock() }
            return last
        }

        var tailText: String {
            lock.lock()
            defer { lock.unlock() }
            return tail.joined(separator: " / ")
        }

        func markStalled() {
            lock.lock()
            defer { lock.unlock() }
            stalled = true
        }

        var isMarkedStalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stalled
        }
    }

    static func run(
        executable: URL, arguments: [String], stallTimeout: TimeInterval = FinalizeStallPolicy.timeout,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        let progress = Progress()
        let reader = Task {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                progress.touch(line)
                onLine(line)
            }
        }
        let interval = min(10, max(0.1, stallTimeout / 3))
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                if FinalizeStallPolicy.isStalled(lastProgress: progress.lastProgress, now: Date(), timeout: stallTimeout) {
                    progress.markStalled()
                    process.terminate()
                    try? await Task.sleep(for: .seconds(5))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            reader.cancel()
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    // 起動の前に取り消されていた場合は、起動した直後に止める
                    if Task.isCancelled {
                        process.terminate()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        watchdog.cancel()
        // 子processの終了後に残っている出力を読み切る。読めなかった場合も、成否は終了状態で決める
        _ = try? await reader.value
        if progress.isMarkedStalled {
            throw FinalizeProcessError.stalled(after: stallTimeout)
        }
        guard status == 0 else {
            throw FinalizeProcessError.exited(status: status, stderrTail: progress.tailText)
        }
    }
}
