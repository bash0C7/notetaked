import Foundation

public enum SignalResponseOutcome: Sendable, Equatable {
    case completed
    case retry(SignalRequest)
    case gaveUp
}

public enum SignalResponseHandling {
    /// HealthKitの読み取りに失敗した応答だけ再試行する。間隔と回数は確定処理の自動再試行と同じ。
    /// 空の応答は完了にする（2回目の要求が遅れて同期された分を拾う）
    public static func outcome(request: SignalRequest, response: SignalResponseMessage, nowMS: Int64)
        -> SignalResponseOutcome
    {
        guard response.sources.hr == .unavailable || response.sources.hrv == .unavailable else { return .completed }
        var next = request
        next.failureCount += 1
        guard let delay = FinalizeRetryPolicy.delay(afterFailureCount: next.failureCount) else { return .gaveUp }
        next.dueAtMS = nowMS + Int64(delay * 1000)
        return .retry(next)
    }

    public static func apply(_ outcome: SignalResponseOutcome, to state: SignalRequestState, requestID: String)
        -> SignalRequestState
    {
        var result = state
        switch outcome {
        case .completed, .gaveUp:
            result.requests.removeAll { $0.id == requestID }
        case .retry(let next):
            if let index = result.requests.firstIndex(where: { $0.id == requestID }) {
                result.requests[index] = next
            }
        }
        return result
    }

    /// ファイルへ重ねる中身。headerは収録全体の区間で、要求の区間からはみ出すバケットは捨てる
    public static func document(request: SignalRequest, response: SignalResponseMessage, nowMS: Int64)
        -> SignalsDocument
    {
        SignalsDocument(
            header: SignalsHeader(
                prefix: request.prefix, start: request.recordingStartMS, end: request.recordingEndMS,
                bucketMS: SignalBucketing.bucketMS, requestedAt: nowMS),
            buckets: SignalBucketing.clip(response.buckets, startMS: request.startMS, endMS: request.endMS))
    }
}

public enum SignalNotice: String, Codable, Sendable {
    /// 1回目の応答に心拍が無い。Watchの心拍はiPhoneへ遅れて同期されるので、2回目を待つ
    case waiting
    case noHeartRate = "no_heart_rate"
    case locationNotAllowed = "location_not_allowed"
}

public struct SignalStateEvent: Codable, Sendable, Equatable {
    public var prefix: String
    public var notices: [SignalNotice]

    public init(prefix: String, notices: [SignalNotice]) {
        self.prefix = prefix
        self.notices = notices
    }
}

public enum SignalNotices {
    /// `merged`は重ねた後のファイルの中身。1回目で取れていれば、2回目が空でも案内しない
    public static func notices(merged: SignalsDocument, sources: SignalSources, round: Int) -> [SignalNotice] {
        var result: [SignalNotice] = []
        if sources.hr == .notRequested || sources.hrv == .notRequested {
            result.append(.noHeartRate)
        } else if !merged.buckets.contains(where: { $0.hr != nil || $0.hrv != nil }) {
            result.append(round >= 2 ? .noHeartRate : .waiting)
        }
        if sources.place == .denied || sources.place == .notDetermined {
            result.append(.locationNotAllowed)
        }
        return result
    }
}

public enum SignalStatusLabel {
    /// 新しい3つの収録の案内を、収録の順に並べる。`lastLog`は確定処理の進捗で上書きされるため、専用の行にする
    public static func menuLines(states: [String: SignalStateEvent]) -> [String] {
        states.keys.sorted().suffix(3).flatMap { prefix in
            (states[prefix]?.notices ?? []).map { line(prefix: prefix, notice: $0) }
        }
    }

    static func line(prefix: String, notice: SignalNotice) -> String {
        switch notice {
        case .waiting:
            return "\(prefix): 心拍はまだ届いていません。30分後にもう一度取ります"
        case .noHeartRate:
            return "\(prefix): 心拍が取れていません。Watchを着けていたか、iPhoneのヘルスケアの許可を確認してください"
        case .locationNotAllowed:
            return "\(prefix): 地点が取れていません。iPhoneの位置情報の許可を確認してください"
        }
    }
}
