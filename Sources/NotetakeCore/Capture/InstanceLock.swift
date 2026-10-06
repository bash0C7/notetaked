import Foundation

/// processに1つだけ持てる排他lock。capture-daemonが2つ同時に同じ生音声へ書かないために使う。
/// lockはprocessの終了（crashやSIGKILLを含む）で自動的に離れる
public final class InstanceLock: @unchecked Sendable {
    // @unchecked Sendable: 開いたfile descriptorだけを持ち、lockの確認は初期化の中で終わる
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// `url`のfileに排他lockを取る。別のprocessか別のInstanceLockが持っていればnilを返す
    public static func acquire(at url: URL) throws -> InstanceLock? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
        return InstanceLock(descriptor: descriptor)
    }
}
