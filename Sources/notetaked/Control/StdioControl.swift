import Foundation
import NotetakeCore

/// stdinの各行をCommandへdecodeし、Eventをstdoutへ1行ずつ書き出すcontrol channel。
/// 書き込みはactorで直列化され、毎回flushする。
actor StdioControl {
    /// stdinの各行をCommandへdecodeして流す。壊れた行はEvent.errorで報告し、読み取りを継続する。
    /// stdinがEOFに達するとstreamはfinishする（呼び出し側はこれをquit相当として扱う）
    func commands() -> AsyncStream<Command> {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        let task = Task {
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    do {
                        continuation.yield(try Command.decode(line: line))
                    } catch {
                        await send(.error("invalid command: \(line)"))
                    }
                }
            } catch {
                await send(.error("stdin read failed: \(error)"))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func send(_ event: Event) async {
        guard let line = try? event.encodedLine() else { return }
        print(line)
        fflush(stdout)
    }
}
