import Foundation
import Testing
@testable import NotetakeCore

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSegment(seq: Int, text: String = "hi") -> Segment {
    Segment(
        id: UUID(),
        session: "s1",
        seq: seq,
        device: "d1",
        deviceName: "d",
        owner: "bash",
        platform: .ios,
        source: .mic,
        start: 0,
        end: 1,
        text: text
    )
}

@Test func nextSeqStartsAtOne() async {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let outbox = Outbox(directory: dir)
    #expect(await outbox.nextSeq() == 1)
}

@Test func appendAdvancesNextSeqAndPendingIncludesIt() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let outbox = Outbox(directory: dir)
    try await outbox.append(makeSegment(seq: 1, text: "a"))
    try await outbox.append(makeSegment(seq: 2, text: "b"))

    #expect(await outbox.nextSeq() == 3)
    let pending = try await outbox.pending()
    #expect(pending.map(\.seq) == [1, 2])
    #expect(pending.map(\.text) == ["a", "b"])
}

@Test func acknowledgeExcludesFromPendingAndDoesNotGoBackwards() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let outbox = Outbox(directory: dir)
    try await outbox.append(makeSegment(seq: 1))
    try await outbox.append(makeSegment(seq: 2))
    try await outbox.append(makeSegment(seq: 3))

    try await outbox.acknowledge(upTo: 2)
    #expect(await outbox.ackedSeq == 2)
    var pending = try await outbox.pending()
    #expect(pending.map(\.seq) == [3])

    try await outbox.acknowledge(upTo: 1) // 後退しない
    #expect(await outbox.ackedSeq == 2)
    pending = try await outbox.pending()
    #expect(pending.map(\.seq) == [3])
}

@Test func reopenRestoresNextSeqAndCursor() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    do {
        let outbox = Outbox(directory: dir)
        try await outbox.append(makeSegment(seq: 1))
        try await outbox.append(makeSegment(seq: 2))
        try await outbox.append(makeSegment(seq: 3))
        try await outbox.acknowledge(upTo: 2)
    }

    let reopened = Outbox(directory: dir)
    #expect(await reopened.nextSeq() == 4)
    #expect(await reopened.ackedSeq == 2)
    let pending = try await reopened.pending()
    #expect(pending.map(\.seq) == [3])
}

@Test func compactDropsAckedLinesButKeepsPending() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let outbox = Outbox(directory: dir)
    try await outbox.append(makeSegment(seq: 1))
    try await outbox.append(makeSegment(seq: 2))
    try await outbox.append(makeSegment(seq: 3))
    try await outbox.acknowledge(upTo: 2)

    try await outbox.compact()

    let text = try String(contentsOf: outbox.outboxURL, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 1)

    let pending = try await outbox.pending()
    #expect(pending.map(\.seq) == [3])

    // compact後もappendを続けられる
    try await outbox.append(makeSegment(seq: 4))
    let pendingAfterAppend = try await outbox.pending()
    #expect(pendingAfterAppend.map(\.seq) == [3, 4])
}

@Test func appendAssigningSeqUsesNextSeqAndAdvances() async throws {
    let outbox = Outbox(directory: makeTempDirectory())
    let first = try await outbox.appendAssigningSeq(makeSegment(seq: 0, text: "a"))
    let second = try await outbox.appendAssigningSeq(makeSegment(seq: 999, text: "b"))
    #expect(first.seq == 1)
    #expect(second.seq == 2)
    #expect(await outbox.nextSeq() == 3)
    let pending = try await outbox.pending()
    #expect(pending.map(\.seq) == [1, 2])
    #expect(pending.map(\.text) == ["a", "b"])
}
