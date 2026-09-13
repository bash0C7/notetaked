import Foundation
import os

/// 実機デバッグ用の診断出力。`xcrun devicectl … --console`で読めるようstderrへも出すが、
/// consoleが切れてstderrが閉じた後に`FileHandle`で書くと`NSFileHandle`例外でappが落ちる
/// （2026-09-13のクラッシュ）ため、C stdioの`fputs`と`SIGPIPE`無視で書き、あわせて
/// unified logging（Console.appで`subsystem`絞り込み）にも出す。
enum Diag {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.bash0c7.notetake.ios", category: "diag")
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    static func log(_ message: String) {
        _ = ignoreSIGPIPE
        logger.info("\(message, privacy: .public)")
        fputs(message + "\n", stderr)
    }
}
