import Foundation

/// 自動の再試行の間隔と回数
public enum FinalizeRetryPolicy {
    /// 失敗の後、次の自動の再試行までの間隔（秒）。1分後・10分後・60分後
    public static let delays: [TimeInterval] = [60, 600, 3_600]

    /// `failureCount`回失敗した後の、次の再試行までの間隔。再試行を使い切っていればnil
    public static func delay(afterFailureCount failureCount: Int) -> TimeInterval? {
        guard failureCount >= 1, failureCount <= delays.count else { return nil }
        return delays[failureCount - 1]
    }

    /// 最初の確定に続く3回の再試行が全て失敗した
    public static func isGivenUp(failureCount: Int) -> Bool {
        failureCount > delays.count
    }
}

/// `finalize-attempts`。自動の再試行で失敗した回数をserveの再起動をまたいで残す
public enum FinalizeAttempts {
    /// ファイルが無ければ0。数として読めなければthrowする
    public static func read(sessionDirectory: URL) throws -> Int {
        let url = CaptureSessionPaths.finalizeAttemptsURL(sessionDirectory: sessionDirectory)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return 0
        }
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return count
    }

    public static func write(_ count: Int, sessionDirectory: URL) throws {
        try AtomicFile.write(
            Data("\(count)\n".utf8), to: CaptureSessionPaths.finalizeAttemptsURL(sessionDirectory: sessionDirectory))
    }

    public static func clear(sessionDirectory: URL) {
        try? FileManager.default.removeItem(
            at: CaptureSessionPaths.finalizeAttemptsURL(sessionDirectory: sessionDirectory))
    }
}
