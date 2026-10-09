import Foundation

/// 心拍の測定値。`at`はepoch ms
public struct HeartRateSample: Sendable, Equatable {
    public var at: Int64
    public var bpm: Double

    public init(at: Int64, bpm: Double) {
        self.at = at
        self.bpm = bpm
    }
}

/// HRV（SDNN）の測定値
public struct HRVSample: Sendable, Equatable {
    public var at: Int64
    public var sdnnMS: Double

    public init(at: Int64, sdnnMS: Double) {
        self.at = at
        self.sdnnMS = sdnnMS
    }
}

/// 登録地点への滞在。`end`がnilはまだ出発していない
public struct PlaceStay: Codable, Sendable, Equatable {
    public var start: Int64
    public var end: Int64?
    public var label: String

    public init(start: Int64, end: Int64?, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }
}

public struct HeartRateSummary: Codable, Sendable, Equatable {
    public var mean: Double
    /// 3件未満では書かない。件数が少ないと最小と最大は測定値そのものになるため
    public var min: Double?
    public var max: Double?
    public var n: Int

    public init(mean: Double, min: Double?, max: Double?, n: Int) {
        self.mean = mean
        self.min = min
        self.max = max
        self.n = n
    }
}

public struct HRVSummary: Codable, Sendable, Equatable {
    public var meanSDNNMS: Double
    public var n: Int

    enum CodingKeys: String, CodingKey {
        case meanSDNNMS = "mean_sdnn_ms"
        case n
    }

    public init(meanSDNNMS: Double, n: Int) {
        self.meanSDNNMS = meanSDNNMS
        self.n = n
    }
}

/// 10分のバケット1つ。`hr` / `hrv`は測定が無ければnullを書き、`partial`と`place`は値がある時だけ書く
public struct SignalBucket: Codable, Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    /// 収録の区間で切り詰めた
    public var partial: Bool
    public var place: String?
    public var hr: HeartRateSummary?
    public var hrv: HRVSummary?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case partial
        case place
        case hr
        case hrv
    }

    public init(
        start: Int64, end: Int64, partial: Bool = false, place: String? = nil,
        hr: HeartRateSummary? = nil, hrv: HRVSummary? = nil
    ) {
        self.start = start
        self.end = end
        self.partial = partial
        self.place = place
        self.hr = hr
        self.hrv = hrv
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int64.self, forKey: .start)
        end = try container.decode(Int64.self, forKey: .end)
        partial = try container.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        place = try container.decodeIfPresent(String.self, forKey: .place)
        hr = try container.decodeIfPresent(HeartRateSummary.self, forKey: .hr)
        hrv = try container.decodeIfPresent(HRVSummary.self, forKey: .hrv)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        if partial {
            try container.encode(true, forKey: .partial)
        }
        try container.encodeIfPresent(place, forKey: .place)
        try container.encode(hr, forKey: .hr)
        try container.encode(hrv, forKey: .hrv)
    }
}
