/// serveの再起動の間隔。回数で諦めず、連続失敗が続くほど間隔だけ伸ばす
public enum ServeRestartPolicy {
    public static let stableSeconds = 30

    public static func delaySeconds(afterFailures failures: Int) -> Int {
        RetryBackoff.seconds(afterFailures: max(failures - 1, 0))
    }

    /// stableSeconds以上生きていたら起動できていたとみなし、数え直す
    public static func consecutiveFailures(previous: Int, ranForSeconds: Int) -> Int {
        ranForSeconds >= stableSeconds ? 1 : previous + 1
    }
}
