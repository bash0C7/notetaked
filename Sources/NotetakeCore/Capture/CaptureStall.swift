import Foundation

/// 取り込みが始まっているのに音声のbufferが届かなくなったかの判定。
/// startの呼び出しが成功しても音声が届かないことがあるため、届いた時刻で判断する
public enum CaptureStall {
    public static let timeout: TimeInterval = 5

    /// bufferがまだ1つも届いていなければ開始から、届いていれば最後に届いた時から`timeout`を過ぎたら途絶とみなす
    public static func isStalled(
        lastBufferAt: Date?, startedAt: Date, now: Date, timeout: TimeInterval = timeout
    ) -> Bool {
        now.timeIntervalSince(lastBufferAt ?? startedAt) > timeout
    }
}
