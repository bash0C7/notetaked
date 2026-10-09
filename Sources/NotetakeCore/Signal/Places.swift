import Foundation

/// userが名前を付けた地点。座標はiPhoneの中にだけ置く
public struct RegisteredPlace: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusM: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case latitude
        case longitude
        case radiusM = "radius_m"
    }

    public init(id: UUID, name: String, latitude: Double, longitude: Double, radiusM: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusM = radiusM
    }
}

public enum PlaceMatcher {
    /// 位置はあるが、どの登録地点にも入らない
    public static let unknownLabel = "不明"

    /// 半径に入る登録地点のうち最も近い地点の名前
    public static func label(latitude: Double, longitude: Double, places: [RegisteredPlace]) -> String {
        places
            .map { place in
                (place, distanceM(latitude1: latitude, longitude1: longitude, latitude2: place.latitude, longitude2: place.longitude))
            }
            .filter { $0.1 <= $0.0.radiusM }
            .min { $0.1 < $1.1 }?.0.name ?? unknownLabel
    }

    /// 2点間の距離（haversine、地球の半径6,371km）
    public static func distanceM(latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (latitude2 - latitude1) * radians
        let deltaLongitude = (longitude2 - longitude1) * radians
        let a =
            sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1 * radians) * cos(latitude2 * radians) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

public enum PlaceStays {
    /// 30日より古い滞在は捨てる。要求は作成から7日で放棄されるので、それより長く持つ理由がない
    public static let retentionMS: Int64 = 30 * 24 * 3_600_000

    /// 滞在を延ばすたびに同じ開始時刻で書き直すので、開始時刻が同じ滞在は置き換える
    public static func upsert(_ stays: [PlaceStay], _ stay: PlaceStay, nowMS: Int64) -> [PlaceStay] {
        var result = stays.filter { $0.start != stay.start }
        result.append(stay)
        return result
            .filter { ($0.end ?? nowMS) >= nowMS - retentionMS }
            .sorted { $0.start < $1.start }
    }

    /// `[startMS, endMS)`と重なる滞在。終わりの無い滞在は今も続いているとみなす
    public static func overlapping(_ stays: [PlaceStay], startMS: Int64, endMS: Int64) -> [PlaceStay] {
        stays.filter { $0.start < endMS && ($0.end ?? Int64.max) > startMS }
    }
}

/// appが動いている間に届く位置から、滞在を作って延ばす
public enum PlaceTracking {
    /// 更新を回している間は1分ごとに延ばすので、これより空いたらappが止まっていたとみなす
    public static let maxGapMS: Int64 = 5 * 60_000

    /// 位置が1件届いた時の今の滞在
    public static func observe(_ current: PlaceStay?, label: String, atMS: Int64) -> PlaceStay {
        if let current, current.label == label {
            let end = current.end ?? current.start
            if atMS <= end {
                return current
            }
            if atMS - end <= maxGapMS {
                return PlaceStay(start: current.start, end: atMS, label: label)
            }
        }
        return PlaceStay(start: atMS, end: atMS, label: label)
    }

    /// 動かず位置が届かない間に、今の滞在の終わりを延ばす。空きが長い時は延ばさない（止まっていた時間をいたことにしない）
    public static func extend(_ current: PlaceStay?, toMS: Int64) -> PlaceStay? {
        guard let current else { return nil }
        let end = current.end ?? current.start
        guard toMS > end, toMS - end <= maxGapMS else { return nil }
        return PlaceStay(start: current.start, end: toMS, label: current.label)
    }
}

/// iPhoneの`place-stays.json`。書き込みはアトミック
public struct PlaceStayLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [PlaceStay] {
        try JSONFile.read([PlaceStay].self, from: url) ?? []
    }

    public func record(_ stay: PlaceStay, nowMS: Int64) throws {
        try JSONFile.write(PlaceStays.upsert(try load(), stay, nowMS: nowMS), to: url)
    }

    public func stays(startMS: Int64, endMS: Int64) throws -> [PlaceStay] {
        PlaceStays.overlapping(try load(), startMS: startMS, endMS: endMS)
    }
}
