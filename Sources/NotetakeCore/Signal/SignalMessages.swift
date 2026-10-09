import Foundation

/// HealthKitの読み取りの状態。HealthKitは読み取りの拒否をappへ教えないので、拒否は`empty`に見える
public enum HealthSourceStatus: String, Codable, Sendable {
    case ok
    case empty
    case notRequested = "not_requested"
    case unavailable
}

/// 位置の許可の状態。`CLLocationManager.authorizationStatus`から取る
public enum PlaceSourceStatus: String, Codable, Sendable {
    case always
    case whenInUse = "when_in_use"
    case denied
    case notDetermined = "not_determined"
    case restricted
}

public struct SignalSources: Codable, Sendable, Equatable {
    public var hr: HealthSourceStatus
    public var hrv: HealthSourceStatus
    public var place: PlaceSourceStatus

    public init(hr: HealthSourceStatus, hrv: HealthSourceStatus, place: PlaceSourceStatus) {
        self.hr = hr
        self.hrv = hrv
        self.place = place
    }
}

/// Macが送る。時刻はMacの時計のepoch msで、iPhoneは自分の時計と同じとみなす（ずれは10分バケットで無視できる）
public struct SignalRequestMessage: Codable, Sendable, Equatable {
    public var id: String
    public var prefix: String
    public var startMS: Int64
    public var endMS: Int64
    public var bucketMS: Int64
    /// 送った時点でMacが送れる状態にある要求の数（この要求を含む）。iPhoneの画面に出す
    public var pending: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case prefix
        case startMS = "start_ms"
        case endMS = "end_ms"
        case bucketMS = "bucket_ms"
        case pending
    }

    public init(id: String, prefix: String, startMS: Int64, endMS: Int64, bucketMS: Int64, pending: Int?) {
        self.id = id
        self.prefix = prefix
        self.startMS = startMS
        self.endMS = endMS
        self.bucketMS = bucketMS
        self.pending = pending
    }
}

/// iPhoneが返す。測定値は10分ごとに集計済みで、生の測定値と座標は含まない
public struct SignalResponseMessage: Codable, Sendable, Equatable {
    public var id: String
    public var prefix: String
    public var sources: SignalSources
    public var buckets: [SignalBucket]

    public init(id: String, prefix: String, sources: SignalSources, buckets: [SignalBucket]) {
        self.id = id
        self.prefix = prefix
        self.sources = sources
        self.buckets = buckets
    }
}
