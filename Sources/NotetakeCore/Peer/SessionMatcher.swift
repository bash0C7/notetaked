import Foundation

public struct SessionSpan: Sendable, Equatable {
    public var prefix: String
    public var startMS: Int64
    /// nil = 進行中
    public var endMS: Int64?

    public init(prefix: String, startMS: Int64, endMS: Int64? = nil) {
        self.prefix = prefix
        self.startMS = startMS
        self.endMS = endMS
    }
}

public enum SessionMatcher {
    /// segの正規化後startが入る収録を返す。進行中(endMS nil)はstart >= startMSで一致。
    /// 過去はstartMS...endMS + toleranceMS。複数なら開始が遅い方。無ければnil（orphan）
    public static func match(segmentStartMS: Int64, sessions: [SessionSpan], toleranceMS: Int64 = 5_000) -> String? {
        let matching = sessions.filter { session in
            if let endMS = session.endMS {
                return segmentStartMS >= session.startMS && segmentStartMS <= endMS + toleranceMS
            } else {
                return segmentStartMS >= session.startMS
            }
        }
        return matching.max { $0.startMS < $1.startMS }?.prefix
    }
}
