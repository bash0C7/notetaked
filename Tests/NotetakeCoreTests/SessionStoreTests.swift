import Foundation
import Testing
@testable import NotetakeCore

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSegment(platform: Platform, text: String) -> Segment {
    Segment(
        id: UUID(),
        session: "s1",
        seq: 1,
        device: "d1",
        deviceName: "d",
        owner: "bash",
        platform: platform,
        source: .mic,
        input: .test,
        start: 0,
        end: 1,
        text: text
    )
}

private func tokyoDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar.date(from: components)!
}

@Test func prefixFormat() {
    let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let date = tokyoDate(year: 2026, month: 9, day: 12, hour: 14, minute: 30, second: 5)
    #expect(SessionStore.prefix(for: date, timeZone: timeZone) == "2026-09-12_143005")
}

@Test func appendWritesTimedAndLive() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let start = tokyoDate(year: 2026, month: 9, day: 12, hour: 14, minute: 30, second: 5)
    let store = SessionStore(directory: dir, start: start, timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    try await store.append(.session(SessionRecord(id: "s1", started: 0, owner: "bash")))
    try await store.append(.segment(makeSegment(platform: .mac, text: "こんにちは")))
    try await store.append(.segment(makeSegment(platform: .ios, text: "やあ")))
    await store.close()

    let timedLines = try String(contentsOf: store.timedURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(timedLines.count == 3)
    for line in timedLines {
        _ = try NDJSON.decode(String(line))
    }

    let liveText = try String(contentsOf: store.liveURL, encoding: .utf8)
    #expect(liveText == "こんにちは\n")
}

@Test func urlsUsePrefix() {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SessionStore(directory: dir, start: Date(), timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    #expect(store.liveURL.lastPathComponent == "\(store.prefix).live.txt")
    #expect(store.timedURL.lastPathComponent == "\(store.prefix).timed.jsonl")
    #expect(store.finalURL.lastPathComponent == "\(store.prefix).final.md")
}

@Test func storeOpenedByPrefixUsesThatPrefix() {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SessionStore(directory: dir, prefix: "2026-10-03_100000")

    #expect(store.prefix == "2026-10-03_100000")
    #expect(store.timedURL.lastPathComponent == "2026-10-03_100000.timed.jsonl")
}

@Test func appendClosesALastLineThatDoesNotEndWithNewline() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir, prefix: "2026-10-03_100000")
    try Data(#"{"type":"session","id":"s"#.utf8).write(to: store.timedURL)

    try await store.append(.session(SessionRecord(id: "s1", started: 0, owner: "bash")))
    await store.close()

    let lines = try String(contentsOf: store.timedURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    #expect(NDJSON.decodeAll(try String(contentsOf: store.timedURL, encoding: .utf8)).count == 1)
}

@Test func appendKeepsALastLineThatEndsWithNewline() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir, prefix: "2026-10-03_100000")

    try await store.append(.session(SessionRecord(id: "s1", started: 0, owner: "bash")))
    await store.close()
    try await store.append(.session(SessionRecord(id: "s2", started: 1, owner: "bash")))
    await store.close()

    let text = try String(contentsOf: store.timedURL, encoding: .utf8)
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
    #expect(NDJSON.decodeAll(text).count == 2)
}
