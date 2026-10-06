import Foundation
import Testing
@testable import NotetakeCore

private func speaker(
    _ id: String, name: String? = nil, seconds: Double, first: Int64, excerpt: String, centroid: [Float]
) -> SpeakersFile.Speaker {
    SpeakersFile.Speaker(
        id: id, source: .system, name: name, speechSeconds: seconds, excerpt: excerpt, firstStartMS: first,
        centroid: centroid)
}

private func sample() -> SpeakersFile {
    SpeakersFile(
        run: 2,
        speakers: [
            speaker("s1", name: "山田太郎", seconds: 30, first: 1_000, excerpt: "最初の話", centroid: [1, 0]),
            speaker("s2", seconds: 10, first: 500, excerpt: "先に話した", centroid: [0, 1]),
        ])
}

@Test func speakersFileRoundTripsWithDocumentedKeys() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = SpeakersFile.url(prefix: "2026-10-06_100000", directory: directory)

    #expect(try SpeakersFile.read(from: url) == nil)
    try sample().write(to: url)
    #expect(try SpeakersFile.read(from: url) == sample())
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"speech_seconds\""))
    #expect(text.contains("\"first_start_ms\""))
}

@Test func theOldArrayFormatIsNotTreatedAsFinalized() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speakers-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("old.speakers.json")
    try AtomicFile.write(Data(#"[{"id":"g1","name":"山田太郎","embedding":[0.1]}]"#.utf8), to: url)
    #expect(try SpeakersFile.read(from: url) == nil)

    try AtomicFile.write(Data("{".utf8), to: url)
    #expect(throws: (any Error).self) {
        _ = try SpeakersFile.read(from: url)
    }
}

@Test func renamingSetsAndClearsTheName() {
    let renamed = sample().renaming(id: "s2", to: " 佐藤花子 ")
    #expect(renamed?.speakers[1].name == "佐藤花子")
    #expect(renamed?.speakers[1].displayName == "佐藤花子")
    #expect(renamed?.renaming(id: "s2", to: "")?.speakers[1].name == nil)
    #expect(sample().speakers[1].displayName == "話者2")
    #expect(sample().renaming(id: "s9", to: "x") == nil)
}

@Test func mergingWeightsTheCentroidBySpeechSecondsAndKeepsTheEarlierExcerpt() throws {
    let merged = try #require(sample().merging(from: "s2", into: "s1"))
    #expect(merged.speakers.map(\.id) == ["s1"])
    let target = merged.speakers[0]
    #expect(target.speechSeconds == 40)
    #expect(target.name == "山田太郎")
    #expect(target.firstStartMS == 500)
    #expect(target.excerpt == "先に話した")
    #expect(abs(target.centroid[0] - 0.75) < 1e-6)
    #expect(abs(target.centroid[1] - 0.25) < 1e-6)
}

@Test func mergingKeepsTheNameOfTheMergedAwaySpeakerWhenTheTargetHasNone() throws {
    var file = sample()
    file.speakers[0].name = nil
    file.speakers[1].name = "佐藤花子"
    #expect(try #require(file.merging(from: "s2", into: "s1")).speakers[0].name == "佐藤花子")
}

@Test func mergingRejectsMissingOrIdenticalSpeakers() {
    #expect(sample().merging(from: "s1", into: "s1") == nil)
    #expect(sample().merging(from: "s9", into: "s1") == nil)
    #expect(sample().merging(from: "s1", into: "s9") == nil)
}

@Test func reconciledAppliesOnlyRecordsOfItsRunAndIsIdempotent() {
    let records: [Record] = [
        .speakerName(SpeakerNameRecord(speaker: "s2", name: "古い回", run: 1)),
        .speakerName(SpeakerNameRecord(speaker: "s2", name: "佐藤花子", run: 2)),
        .speakerMerge(SpeakerMergeRecord(run: 2, from: "s2", into: "s1")),
        .speakerName(SpeakerNameRecord(speaker: "g1", name: "従来")),
    ]
    let once = sample().reconciled(with: records)
    #expect(once.speakers.map(\.id) == ["s1"])
    #expect(once.speakers[0].name == "山田太郎")
    #expect(once.reconciled(with: records) == once)
}
