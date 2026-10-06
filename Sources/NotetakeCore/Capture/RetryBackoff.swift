/// 取り込みの再試行の間隔。1秒から倍にしていき、30秒で頭打ちにする
public enum RetryBackoff {
    public static let maxSeconds = 30

    public static func seconds(afterFailures failures: Int) -> Int {
        guard failures < 5 else { return maxSeconds }
        return min(1 << failures, maxSeconds)
    }
}
