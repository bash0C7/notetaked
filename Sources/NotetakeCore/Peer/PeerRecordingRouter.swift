import Foundation

public enum PeerRoute: Sendable, Equatable {
    case current
    case other(prefix: String)
    /// `create`があれば、新しく作るpeerの収録の`session`の記録
    case peerRecording(prefix: String, create: SessionRecord?)
}

public enum PeerRecordingRouter {
    /// peerのsegの行き先。Macの収録（`current` / `other`）の判定は従来のまま、
    /// 今までorphansへ行っていたものだけを、端末とsessionごとのpeerの収録へ振り分ける
    public static func route(
        segment: Segment, normalizedStartMS: Int64, spans: [SessionSpan], currentPrefix: String?, recording: Bool,
        timeZone: TimeZone
    ) -> PeerRoute {
        if let matched = SessionMatcher.match(segmentStartMS: normalizedStartMS, sessions: spans) {
            if recording, matched == currentPrefix { return .current }
            return .other(prefix: matched)
        }
        let key = "\(segment.device)/\(segment.session)"
        if let existing = spans.first(where: { $0.origin == .peer && $0.peerKey == key }) {
            return .peerRecording(prefix: existing.prefix, create: nil)
        }
        let started = min(startMS(of: segment, fallback: normalizedStartMS, timeZone: timeZone), normalizedStartMS)
        let base =
            SessionStore.prefix(for: Date(timeIntervalSince1970: Double(started) / 1000), timeZone: timeZone)
            + (segment.platform == .watchos ? "-watch" : "-iphone")
        let taken = Set(spans.map(\.prefix))
        var prefix = base
        var number = 2
        while taken.contains(prefix) {
            prefix = "\(base)-\(number)"
            number += 1
        }
        let create = SessionRecord(
            id: prefix, started: started, owner: segment.owner, origin: .peer, peerDevice: segment.device,
            peerSession: segment.session)
        return .peerRecording(prefix: prefix, create: create)
    }

    /// Watchのsessionはepoch ms、iPhoneのsessionは収録のprefix。どちらでもなければsegの開始
    private static func startMS(of segment: Segment, fallback: Int64, timeZone: TimeZone) -> Int64 {
        if let ms = Int64(segment.session) { return ms }
        if let date = SessionStore.date(fromPrefix: segment.session, timeZone: timeZone) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return fallback
    }
}
