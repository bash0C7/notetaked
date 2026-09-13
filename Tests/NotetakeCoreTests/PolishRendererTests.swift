import Foundation
import Testing
@testable import NotetakeCore

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let recordedAt = Date(timeIntervalSince1970: 1_789_300_000)   // 2026-09-13 JST

@Test func rendersHeaderWithDateAndParticipantsThenDialogue() {
    let turns = [
        PolishedTurn(speaker: "小芝", text: "こんにちは", polished: true),
        PolishedTurn(speaker: "田中", text: "うん", polished: true),
        PolishedTurn(speaker: "小芝", text: "そう", polished: true),
    ]
    let result = PolishRenderer.markdown(turns, recordedAt: recordedAt, timeZone: tokyo)
    #expect(result == "# 2026-09-13 小芝、田中\n\n**小芝**: こんにちは\n**田中**: うん\n**小芝**: そう\n")
}

@Test func replacesNewlinesWithSpace() {
    let turn = PolishedTurn(speaker: "小芝", text: "a\nb", polished: true)
    let result = PolishRenderer.markdown([turn], recordedAt: recordedAt, timeZone: tokyo)
    #expect(result.hasSuffix("**小芝**: a b\n"))
}

@Test func appendsFailureFooterWhenAnyTurnNotPolished() {
    let turns = [
        PolishedTurn(speaker: "小芝", text: "こんにちは", polished: true),
        PolishedTurn(speaker: "田中", text: "うん", polished: false),
    ]
    let result = PolishRenderer.markdown(turns, recordedAt: recordedAt, timeZone: tokyo)
    #expect(result.hasSuffix("**田中**: うん\n\n> 整形に失敗したturn: 1件（原文のまま）\n"))
}

@Test func participantsAreInOrderOfAppearanceWithoutDuplicates() {
    let turns = [
        PolishedTurn(speaker: "田中", text: "a", polished: true),
        PolishedTurn(speaker: "小芝", text: "b", polished: true),
        PolishedTurn(speaker: "田中", text: "c", polished: true),
    ]
    #expect(PolishRenderer.participants(turns) == ["田中", "小芝"])
}

@Test func emptyIsEmpty() {
    #expect(PolishRenderer.markdown([], recordedAt: recordedAt, timeZone: tokyo) == "")
}
