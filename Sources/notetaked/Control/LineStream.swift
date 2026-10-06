import Foundation

/// fdを専用のthreadで読み、行ごとに流す。EOFか読み取りの失敗で終わる。
/// `FileHandle.bytes`は読み取りを共有のキューで行うため、stdinのように来ない入力を待つ読み取りが1つあると、
/// 同時に読む別のpipeの行が届かなくなる。そのため入力ごとに専用のthreadで読む
enum LineStream {
    static func lines(of descriptor: Int32) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let thread = Thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(buffer, count: count)
                while let newline = pending.firstIndex(of: 0x0A) {
                    continuation.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty {
                continuation.yield(String(decoding: pending, as: UTF8.self))
            }
            continuation.finish()
        }
        thread.name = "LineStream.\(descriptor)"
        thread.start()
        return stream
    }
}
