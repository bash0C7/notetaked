import Foundation

public struct SessionSpan: Sendable, Equatable {
    public var prefix: String
    public var startMS: Int64
    /// nil = 進行中
    public var endMS: Int64?
    public var origin: SessionOrigin
    /// peerの収録の`"<device>/<session>"`。macの収録はnil
    public var peerKey: String?

    public init(
        prefix: String, startMS: Int64, endMS: Int64? = nil,
        origin: SessionOrigin = .mac, peerKey: String? = nil
    ) {
        self.prefix = prefix
        self.startMS = startMS
        self.endMS = endMS
        self.origin = origin
        self.peerKey = peerKey
    }
}

public enum SessionMatcher {
    /// segの正規化後startが入る収録を返す。進行中(endMS nil)はstart >= startMSで一致。
    /// 過去はstartMS...endMS + toleranceMS。複数なら開始が遅い方。無ければnil（orphan）。
    /// peerの収録は`(device, session)`で選ぶので、時刻では照合しない
    public static func match(segmentStartMS: Int64, sessions: [SessionSpan], toleranceMS: Int64 = 5_000) -> String? {
        let matching = sessions.filter { session in
            guard session.origin == .mac else { return false }
            if let endMS = session.endMS {
                return segmentStartMS >= session.startMS && segmentStartMS <= endMS + toleranceMS
            } else {
                return segmentStartMS >= session.startMS
            }
        }
        return matching.max { $0.startMS < $1.startMS }?.prefix
    }
}
