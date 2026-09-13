import Foundation

/// Watch側の録音小片（20秒AAC）に付随するmetadata。
/// `WCSession.transferFile` の `metadata`（`[String: Any]`、plist型のみ）と往復する。
/// keyはsnake_case: `session`, `index`, `start_at_ms`, `sample_rate`, `device`, `device_name`, `owner`
public struct WatchChunkMetadata: Sendable, Equatable {
    /// Watch側の収録id（開始時刻ms文字列）
    public var session: String
    /// 0始まりの小片番号
    public var index: Int
    /// 小片先頭の絶対時刻（Watch時計、epoch ms）
    public var startAtMS: Int64
    public var sampleRate: Double
    public var device: String
    public var deviceName: String
    public var owner: String

    public init(
        session: String,
        index: Int,
        startAtMS: Int64,
        sampleRate: Double,
        device: String,
        deviceName: String,
        owner: String
    ) {
        self.session = session
        self.index = index
        self.startAtMS = startAtMS
        self.sampleRate = sampleRate
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
    }

    /// 型が合わなければnil（`startAtMS`はNSNumber/Int/Int64/Doubleを許容）
    public init?(metadata: [String: Any]) {
        guard
            let session = metadata["session"] as? String,
            let index = metadata["index"] as? Int,
            let startAtMS = Self.int64Value(metadata["start_at_ms"]),
            let sampleRate = metadata["sample_rate"] as? Double,
            let device = metadata["device"] as? String,
            let deviceName = metadata["device_name"] as? String,
            let owner = metadata["owner"] as? String
        else {
            return nil
        }

        self.session = session
        self.index = index
        self.startAtMS = startAtMS
        self.sampleRate = sampleRate
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
    }

    public var metadata: [String: Any] {
        [
            "session": session,
            "index": index,
            "start_at_ms": startAtMS,
            "sample_rate": sampleRate,
            "device": device,
            "device_name": deviceName,
            "owner": owner,
        ]
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        switch any {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            guard value.isFinite else { return nil }
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }
}

/// 小片をindex昇順で流す。次に流すべきindexより大きい小片は保留し、
/// 保留数が`maxPending`を超えたら飛ばして進める（飛んだ小片はあとから届いても捨てる）。
/// sessionはインスタンスごとに1つだけ扱う（最初に受け取ったsessionと異なるものは無視する）
public struct WatchChunkSequencer: Sendable {
    private let maxPending: Int
    private var session: String?
    private var pending: [Int: WatchChunkMetadata] = [:]
    public private(set) var nextIndex: Int = 0

    public init(maxPending: Int = 3) {
        self.maxPending = maxPending
    }

    /// いま流してよい小片をindex順で返す（受け入れたものを含む）
    public mutating func accept(_ meta: WatchChunkMetadata) -> [WatchChunkMetadata] {
        if let session {
            guard session == meta.session else { return [] }
        } else {
            session = meta.session
        }

        guard meta.index >= nextIndex else {
            return []
        }

        if meta.index == nextIndex {
            var out = [meta]
            nextIndex += 1
            out.append(contentsOf: drainConsecutivePending())
            return out
        }

        pending[meta.index] = meta
        guard pending.count > maxPending else {
            return []
        }

        guard let smallest = pending.keys.min() else {
            return []
        }
        nextIndex = smallest
        return drainConsecutivePending()
    }

    /// 保留を全部index順で出す（停止時）
    public mutating func flush() -> [WatchChunkMetadata] {
        let sortedKeys = pending.keys.sorted()
        let out = sortedKeys.map { pending.removeValue(forKey: $0)! }
        if let last = sortedKeys.last {
            nextIndex = last + 1
        }
        return out
    }

    private mutating func drainConsecutivePending() -> [WatchChunkMetadata] {
        var out: [WatchChunkMetadata] = []
        while let next = pending.removeValue(forKey: nextIndex) {
            out.append(next)
            nextIndex += 1
        }
        return out
    }
}
