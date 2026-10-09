import Foundation
import Testing
@testable import NotetakeCore

private let minute: Int64 = 60_000
private let station = RegisteredPlace(id: UUID(), name: "東京駅", latitude: 35.681236, longitude: 139.767125, radiusM: 100)
private let office = RegisteredPlace(id: UUID(), name: "オフィス", latitude: 35.682836, longitude: 139.767125, radiusM: 100)

@Test func placeMatcherPicksTheNearestPlaceWithinItsRadius() {
    // 東京駅から北へ約33m、オフィスから南へ約145m
    #expect(PlaceMatcher.label(latitude: 35.681536, longitude: 139.767125, places: [station, office]) == "東京駅")
    // オフィスから南へ約78m。東京駅からは約100mで半径の外
    #expect(PlaceMatcher.label(latitude: 35.682136, longitude: 139.767125, places: [station, office]) == "オフィス")
    // どちらからも約1km
    #expect(PlaceMatcher.label(latitude: 35.690000, longitude: 139.767125, places: [station, office]) == "不明")
}

@Test func placeMatcherDistanceIsAboutOneHundredAndElevenMetersPerMilliDegreeOfLatitude() {
    let distance = PlaceMatcher.distanceM(latitude1: 35.0, longitude1: 139.0, latitude2: 35.001, longitude2: 139.0)
    #expect(abs(distance - 111.2) < 0.5)
}

@Test func placeStaysUpsertReplacesTheStayWithTheSameArrival() {
    let open = PlaceStay(start: 0, end: nil, label: "自宅")
    let closed = PlaceStay(start: 0, end: 30 * minute, label: "自宅")
    #expect(PlaceStays.upsert([open], closed, nowMS: 31 * minute) == [closed])
}

@Test func placeStaysUpsertDropsStaysOlderThanTheRetention() {
    let old = PlaceStay(start: 0, end: 10 * minute, label: "自宅")
    let new = PlaceStay(start: PlaceStays.retentionMS + 20 * minute, end: nil, label: "オフィス")
    #expect(PlaceStays.upsert([old], new, nowMS: PlaceStays.retentionMS + 30 * minute) == [new])
}

@Test func placeStaysOverlappingIncludesOpenStays() {
    let stays = [
        PlaceStay(start: 0, end: 10 * minute, label: "自宅"),
        PlaceStay(start: 20 * minute, end: nil, label: "オフィス"),
    ]
    #expect(PlaceStays.overlapping(stays, startMS: 15 * minute, endMS: 40 * minute).map(\.label) == ["オフィス"])
    #expect(PlaceStays.overlapping(stays, startMS: 5 * minute, endMS: 25 * minute).map(\.label) == ["自宅", "オフィス"])
}

@Test func placeStayLogPersistsRecordedStays() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("place-stays.json")
    let log = PlaceStayLog(url: url)
    #expect(try log.load().isEmpty)
    try log.record(PlaceStay(start: 0, end: nil, label: "自宅"), nowMS: minute)
    try log.record(PlaceStay(start: 0, end: 10 * minute, label: "自宅"), nowMS: 11 * minute)
    #expect(try PlaceStayLog(url: url).stays(startMS: 0, endMS: 5 * minute) == [PlaceStay(start: 0, end: 10 * minute, label: "自宅")])
}

@Test func placeTrackingExtendsTheSameLabelWithinTheGap() {
    let current = PlaceStay(start: 0, end: 2 * minute, label: "自宅")
    #expect(PlaceTracking.observe(current, label: "自宅", atMS: 6 * minute, trackingSinceMS: 0) == PlaceStay(start: 0, end: 6 * minute, label: "自宅"))
}

@Test func placeTrackingStartsANewStayWhenTheLabelChanges() {
    let current = PlaceStay(start: 0, end: 2 * minute, label: "自宅")
    #expect(PlaceTracking.observe(current, label: "不明", atMS: 3 * minute, trackingSinceMS: 0) == PlaceStay(start: 3 * minute, end: 3 * minute, label: "不明"))
}

@Test func placeTrackingStartsANewStayAfterAGapLongerThanFiveMinutes() {
    // appが止まっていた時間を、いたことにしない
    let current = PlaceStay(start: 0, end: 2 * minute, label: "自宅")
    #expect(PlaceTracking.observe(current, label: "自宅", atMS: 8 * minute, trackingSinceMS: 0) == PlaceStay(start: 8 * minute, end: 8 * minute, label: "自宅"))
}

@Test func placeTrackingStartsTheFirstStayWithoutACurrentOne() {
    #expect(PlaceTracking.observe(nil, label: "自宅", atMS: minute, trackingSinceMS: 0) == PlaceStay(start: minute, end: minute, label: "自宅"))
}

@Test func placeTrackingDoesNotShrinkTheStayForAnEarlierFix() {
    let current = PlaceStay(start: 0, end: 4 * minute, label: "自宅")
    #expect(PlaceTracking.observe(current, label: "自宅", atMS: 3 * minute, trackingSinceMS: 0) == current)
}

@Test func placeTrackingDoesNotStartAStayBeforeTrackingBegan() {
    // iOSが前のsessionから持っている古い位置を、追跡の開始より前にいたことにしない
    #expect(
        PlaceTracking.observe(nil, label: "自宅", atMS: 2 * minute, trackingSinceMS: 5 * minute)
            == PlaceStay(start: 5 * minute, end: 5 * minute, label: "自宅"))
    let previousSession = PlaceStay(start: 0, end: 2 * minute, label: "自宅")
    #expect(
        PlaceTracking.observe(previousSession, label: "自宅", atMS: 2 * minute + 30_000, trackingSinceMS: 9 * minute)
            == PlaceStay(start: 9 * minute, end: 9 * minute, label: "自宅"))
}

@Test func placeTrackingExtendsWithoutAFixOnlyWithinTheGap() {
    let current = PlaceStay(start: 0, end: 2 * minute, label: "自宅")
    #expect(PlaceTracking.extend(current, toMS: 3 * minute) == PlaceStay(start: 0, end: 3 * minute, label: "自宅"))
    #expect(PlaceTracking.extend(current, toMS: 8 * minute) == nil)
    #expect(PlaceTracking.extend(current, toMS: minute) == nil)
    #expect(PlaceTracking.extend(nil, toMS: minute) == nil)
}
