import Foundation
import Testing
@testable import NotetakeCore

private func epochMS(
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, timeZone: TimeZone
) -> Int64 {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    return Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1000)
}

@Test func rendersLineWithTimeWhenStartMSPresent() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let start = epochMS(year: 2026, month: 9, day: 12, hour: 14, minute: 30, second: 5, timeZone: tokyo)
    let turn = PolishedTurn(speaker: "小芝", text: "こんにちは", startMS: start, polished: true)

    let result = PolishRenderer.markdown([turn], timeZone: tokyo)

    #expect(result == "14:30:05 **小芝**: こんにちは\n")
}

@Test func rendersLineWithoutTimeWhenStartMSNil() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let turn = PolishedTurn(speaker: "小芝", text: "こんにちは", startMS: nil, polished: true)

    let result = PolishRenderer.markdown([turn], timeZone: tokyo)

    #expect(result == "**小芝**: こんにちは\n")
}

@Test func replacesNewlinesWithSpace() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let turn = PolishedTurn(speaker: "小芝", text: "a\nb", startMS: nil, polished: true)

    let result = PolishRenderer.markdown([turn], timeZone: tokyo)

    #expect(result == "**小芝**: a b\n")
}

@Test func appendsFailureFooterWhenAnyTurnNotPolished() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let turns = [
        PolishedTurn(speaker: "小芝", text: "こんにちは", startMS: nil, polished: true),
        PolishedTurn(speaker: "田中", text: "うん", startMS: nil, polished: false),
        PolishedTurn(speaker: "小芝", text: "そう", startMS: nil, polished: false),
    ]

    let result = PolishRenderer.markdown(turns, timeZone: tokyo)

    #expect(result == "**小芝**: こんにちは\n**田中**: うん\n**小芝**: そう\n\n> 整形に失敗したturn: 2件（原文のまま）\n")
}

@Test func noFooterWhenAllPolished() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let turns = [
        PolishedTurn(speaker: "小芝", text: "こんにちは", startMS: nil, polished: true),
    ]

    let result = PolishRenderer.markdown(turns, timeZone: tokyo)

    #expect(!result.contains("整形に失敗"))
}

@Test func emptyIsEmpty() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    #expect(PolishRenderer.markdown([], timeZone: tokyo) == "")
}
