import Foundation

/// 子processの進捗が途絶えた時の判断
public enum FinalizeStallPolicy {
    public static let timeout: TimeInterval = 300

    public static func isStalled(lastProgress: Date, now: Date, timeout: TimeInterval = timeout) -> Bool {
        now.timeIntervalSince(lastProgress) > timeout
    }
}

/// 確定処理を始めてよいか
public enum FinalizeGate {
    /// capture-daemonがその収録へ書き終えていれば始めてよい。実状態のprefixが別になった、
    /// 実状態が無い、または古くてcapture-daemonが動いていないなら書き終えている
    public static func canStart(prefix: String, actual: CaptureActualState?, nowMS: Int64) -> Bool {
        guard let actual else { return true }
        if nowMS - actual.updated > CaptureActualWatcher.staleAfterMS { return true }
        return actual.prefix != prefix
    }
}
