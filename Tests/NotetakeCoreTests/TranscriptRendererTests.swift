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

private func utterance(
    id: UUID = UUID(),
    start: Int64,
    end: Int64? = nil,
    speakerID: String? = nil,
    speaker: String,
    text: String,
    confidence: Double? = nil,
    source: Source = .mic,
    platform: Platform = .mac,
    ownerLabel: String? = nil,
    input: String = "MacBook Airのマイク",
    sources: [UUID] = [],
    devices: [String] = [],
    direction: Direction? = nil
) -> Utterance {
    Utterance(
        id: id,
        start: start,
        end: end ?? start,
        speakerID: speakerID,
        speaker: speaker,
        text: text,
        confidence: confidence,
        source: source,
        platform: platform,
        ownerLabel: ownerLabel ?? speaker,
        input: input,
        sources: sources,
        devices: devices,
        direction: direction
    )
}

@Test func rendersLineWithLocalTime() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let start = epochMS(year: 2026, month: 9, day: 12, hour: 14, minute: 30, second: 5, timeZone: tokyo)
    let u = utterance(start: start, speaker: "小芝", text: "こんにちは")

    let result = TranscriptRenderer.markdown([u], timeZone: tokyo)

    #expect(result == "14:30:05 **小芝**（Mac）: こんにちは\n")
}

@Test func rendersInOrderAndReplacesNewlines() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let first = utterance(start: 0, speaker: "小芝", text: "おはよう")
    let second = utterance(start: 1000, speaker: "田中", text: "a\nb")

    let result = TranscriptRenderer.markdown([first, second], timeZone: tokyo)
    let lines = result.split(separator: "\n")

    #expect(lines.count == 2)
    #expect(lines[0].hasSuffix("**小芝**（Mac）: おはよう"))
    #expect(lines[1].hasSuffix("**田中**（Mac）: a b"))
}

@Test func emptyIsEmpty() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    #expect(TranscriptRenderer.markdown([], timeZone: tokyo) == "")
}

@Test func replacesCRLFAndCR() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let start = epochMS(year: 2026, month: 9, day: 12, hour: 14, minute: 30, second: 5, timeZone: tokyo)
    let u = utterance(start: start, speaker: "小芝", text: "a\r\nb\rc")

    let result = TranscriptRenderer.markdown([u], timeZone: tokyo)

    #expect(result == "14:30:05 **小芝**（Mac）: a b c\n")
}

@Test func rendersDirectionAsClockPosition() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let u = utterance(start: 0, speaker: "田中", text: "はい", source: .mic,
                      platform: .ios, input: "iPhone マイク",
                      direction: Direction(azimuthDeg: 90, confidence: 0.9))
    let line = TranscriptRenderer.markdown([u], timeZone: tokyo)
    #expect(line.hasSuffix("**田中**（iPhone 3時）: はい\n"))
}
