import Foundation

/// 停止中のマイク音量モニターを動かすかどうかの判定。
/// 収録中、および収録の開始を送ってからdaemonが収録中と伝えるまでの間は、
/// capture-daemonがマイクを持つので、モニターは同時にマイクを持たない
public enum MicMonitorPolicy {
    public static func shouldMonitor(windowVisible: Bool, isRecording: Bool, isStartPending: Bool) -> Bool {
        windowVisible && !isRecording && !isStartPending
    }
}
