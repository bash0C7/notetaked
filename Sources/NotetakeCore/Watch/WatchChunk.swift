import Foundation

/// Watch側の録音小片（20秒AAC）に付随するmetadata。
/// `WCSession.transferFile` の `metadata`（`[String: Any]`、plist型のみ）と往復する。
/// keyはsnake_case: `session`, `index`, `start_at_ms`, `sample_rate`, `device`, `device_name`, `owner`
/// 任意項目（無ければkeyごと出さない）: `max_dbfs`, `mean_dbfs`, `battery_level`, `max_queue_depth`, `duration_ms`, `is_final`
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
    /// 小片内の最大dBFS（旧形式のmetadataには無い）
    public var maxDBFS: Double?
    public var meanDBFS: Double?
    /// 小片を閉じた時点の電池残量（0...1）
    public var batteryLevel: Double?
    /// 小片の間にWatch側で待っていた転送の最大数
    public var maxQueueDepth: Int?
    /// 小片の長さ（ms）
    public var durationMS: Int64?
    /// 停止で閉じた最後の小片だけtrue
    public var isFinal: Bool?

    public init(
        session: String,
        index: Int,
        startAtMS: Int64,
        sampleRate: Double,
        device: String,
        deviceName: String,
        owner: String,
        maxDBFS: Double? = nil,
        meanDBFS: Double? = nil,
        batteryLevel: Double? = nil,
        maxQueueDepth: Int? = nil,
        durationMS: Int64? = nil,
        isFinal: Bool? = nil
    ) {
        self.session = session
        self.index = index
        self.startAtMS = startAtMS
        self.sampleRate = sampleRate
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.maxDBFS = maxDBFS
        self.meanDBFS = meanDBFS
        self.batteryLevel = batteryLevel
        self.maxQueueDepth = maxQueueDepth
        self.durationMS = durationMS
        self.isFinal = isFinal
    }

    /// 必須の7項目の型が合わなければnil（`startAtMS`はNSNumber/Int/Int64/Doubleを許容）。
    /// 追加の6項目は任意で、無いか型が合わなければその項目だけnil
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
        self.maxDBFS = Self.doubleValue(metadata["max_dbfs"])
        self.meanDBFS = Self.doubleValue(metadata["mean_dbfs"])
        self.batteryLevel = Self.doubleValue(metadata["battery_level"])
        self.maxQueueDepth = Self.intValue(metadata["max_queue_depth"])
        self.durationMS = Self.optionalInt64Value(metadata["duration_ms"])
        self.isFinal = Self.boolValue(metadata["is_final"])
    }

    /// `metadata`を`.sortedKeys`で1行にしたJSON。WatchとiPhoneのsidecarが同じ形で保存するための唯一の書き方
    public func encodedJSON() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// JSONでは`48000.0`が`48000`になり`true`が`NSNumber`になるが、`init?(metadata:)`がその形も読む
    public init?(json: String) {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let dict = object as? [String: Any]
        else {
            return nil
        }
        self.init(metadata: dict)
    }

    public var metadata: [String: Any] {
        var dict: [String: Any] = [
            "session": session,
            "index": index,
            "start_at_ms": startAtMS,
            "sample_rate": sampleRate,
            "device": device,
            "device_name": deviceName,
            "owner": owner,
        ]
        if let maxDBFS { dict["max_dbfs"] = maxDBFS }
        if let meanDBFS { dict["mean_dbfs"] = meanDBFS }
        if let batteryLevel { dict["battery_level"] = batteryLevel }
        if let maxQueueDepth { dict["max_queue_depth"] = maxQueueDepth }
        if let durationMS { dict["duration_ms"] = durationMS }
        if let isFinal { dict["is_final"] = isFinal }
        return dict
    }

    private static func isBool(_ any: Any?) -> Bool {
        guard let number = any as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        guard !isBool(any) else { return nil }
        let value: Double
        switch any {
        case let v as Double:
            value = v
        case let v as Int:
            value = Double(v)
        case let v as NSNumber:
            value = v.doubleValue
        default:
            return nil
        }
        return value.isFinite ? value : nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        guard !isBool(any) else { return nil }
        let value: Int
        switch any {
        case let v as Int:
            value = v
        case let v as NSNumber:
            value = v.intValue
        default:
            return nil
        }
        return value >= 0 ? value : nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        guard isBool(any), let number = any as? NSNumber else { return nil }
        return number.boolValue
    }

    /// 任意項目用。bool・nilや型違いはnil
    private static func optionalInt64Value(_ any: Any?) -> Int64? {
        guard !isBool(any) else { return nil }
        return int64Value(any)
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
