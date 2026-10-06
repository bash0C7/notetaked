import Foundation
import Testing
@testable import NotetakeCore

private func segment(
    device: String = "mac1",
    source: Source = .mic,
    start: Int64,
    text: String,
    speaker: String? = nil,
    pass: SegmentPass? = nil,
    run: Int? = nil
) -> Record {
    .segment(
        Segment(
            id: UUID(), session: "p", seq: 0, device: device, deviceName: device, owner: "山田太郎",
            platform: .mac, source: source, input: .test, start: start, end: start + 1_000, text: text,
            speaker: speaker.map { SpeakerTag(global: $0) }, pass: pass, run: run))
}

private func finalized(_ run: Int, device: String = "mac1", sources: [Source] = [.mic, .system]) -> Record {
    .finalized(FinalizedRecord(run: run, device: device, sources: sources))
}

private func texts(_ records: [Record]) -> [String] {
    Reconciler.fold(records).map(\.text)
}

@Test func finalSegmentsReplaceProvisionalOnesOfTheSameDeviceAndSource() {
    let records: [Record] = [
        segment(start: 0, text: "暫定"),
        segment(start: 10_000, text: "暫定の二つ目"),
        segment(start: 0, text: "確定", speaker: "s1", pass: .final, run: 1),
        finalized(1),
    ]
    #expect(texts(records) == ["確定"])
}

@Test func onlyTheLatestFinalizedRunIsRendered() {
    let records: [Record] = [
        segment(start: 0, text: "一回目", pass: .final, run: 1),
        finalized(1),
        segment(start: 0, text: "二回目", pass: .final, run: 2),
        finalized(2),
    ]
    #expect(texts(records) == ["二回目"])
}

@Test func finalSegmentsWithoutTheirFinalizedRecordAreIgnored() {
    let records: [Record] = [
        segment(start: 0, text: "暫定"),
        segment(start: 0, text: "取り込みの途中", pass: .final, run: 1),
    ]
    #expect(texts(records) == ["暫定"])
}

@Test func provisionalSegmentsOfOtherDevicesAndSourcesAreKept() {
    let records: [Record] = [
        segment(start: 0, text: "Macの暫定"),
        segment(device: "iphone1", start: 20_000, text: "iPhoneの発話"),
        segment(source: .system, start: 40_000, text: "systemの暫定"),
        segment(start: 0, text: "Macの確定", pass: .final, run: 1),
        finalized(1, sources: [.mic]),
    ]
    #expect(texts(records) == ["Macの確定", "iPhoneの発話", "systemの暫定"])
}

@Test func recordsWithoutAnyFinalizedRecordFoldAsBefore() {
    let records: [Record] = [
        segment(start: 0, text: "一つ目", speaker: "g1"),
        segment(start: 10_000, text: "二つ目", speaker: "g1"),
        .speakerName(SpeakerNameRecord(speaker: "g1", name: "佐藤花子")),
    ]
    let utterances = Reconciler.fold(records)
    #expect(utterances.map(\.speaker) == ["佐藤花子", "佐藤花子"])
}

@Test func namesAndMergesApplyOnlyToTheRunInUse() {
    let records: [Record] = [
        segment(start: 0, text: "一回目", speaker: "s1", pass: .final, run: 1),
        finalized(1),
        .speakerName(SpeakerNameRecord(speaker: "s1", name: "古い名前", run: 1)),
        segment(start: 0, text: "二回目", speaker: "s1", pass: .final, run: 2),
        finalized(2),
        .speakerName(SpeakerNameRecord(speaker: "s1", name: "山田太郎", run: 2)),
    ]
    let utterances = Reconciler.fold(records)
    #expect(utterances.map(\.speaker) == ["山田太郎"])
}

@Test func unnamedFinalSpeakersAreNumbered() {
    let records: [Record] = [
        segment(start: 0, text: "一つ目", speaker: "s1", pass: .final, run: 1),
        segment(start: 5_000, text: "二つ目", speaker: "s2", pass: .final, run: 1),
        finalized(1),
    ]
    #expect(Reconciler.fold(records).map(\.speaker) == ["話者1", "話者2"])
}

@Test func mergeMovesTheSpeakerAndKeepsTheNameOfTheTarget() {
    let records: [Record] = [
        segment(start: 0, text: "一つ目", speaker: "s1", pass: .final, run: 1),
        segment(start: 5_000, text: "二つ目", speaker: "s2", pass: .final, run: 1),
        finalized(1),
        .speakerName(SpeakerNameRecord(speaker: "s1", name: "山田太郎", run: 1)),
        .speakerName(SpeakerNameRecord(speaker: "s2", name: "佐藤花子", run: 1)),
        .speakerMerge(SpeakerMergeRecord(run: 1, from: "s2", into: "s1")),
    ]
    let utterances = Reconciler.fold(records)
    #expect(utterances.map(\.speaker) == ["山田太郎", "山田太郎"])
    #expect(utterances.map(\.speakerID) == ["s1", "s1"])
}

@Test func mergeCarriesTheNameOfTheMergedAwaySpeakerWhenTheTargetHasNone() {
    let records: [Record] = [
        segment(start: 0, text: "一つ目", speaker: "s1", pass: .final, run: 1),
        segment(start: 5_000, text: "二つ目", speaker: "s2", pass: .final, run: 1),
        finalized(1),
        .speakerName(SpeakerNameRecord(speaker: "s2", name: "佐藤花子", run: 1)),
        .speakerMerge(SpeakerMergeRecord(run: 1, from: "s2", into: "s1")),
    ]
    #expect(Reconciler.fold(records).map(\.speaker) == ["佐藤花子", "佐藤花子"])
}

@Test func mergeAppliesToSegmentsThatArriveAfterIt() {
    var reconciler = Reconciler()
    reconciler.apply(.speakerMerge(SpeakerMergeRecord(run: 1, from: "s2", into: "s1")))
    reconciler.apply(segment(start: 0, text: "後から届いた", speaker: "s2", pass: .final, run: 1))
    #expect(reconciler.utterances.map(\.speakerID) == ["s1"])
}

@Test func emptyNameRestoresTheDefaultName() {
    let records: [Record] = [
        segment(start: 0, text: "発話", speaker: "s1", pass: .final, run: 1),
        finalized(1),
        .speakerName(SpeakerNameRecord(speaker: "s1", name: "山田太郎", run: 1)),
        .speakerName(SpeakerNameRecord(speaker: "s1", name: " ", run: 1)),
    ]
    #expect(Reconciler.fold(records).map(\.speaker) == ["話者1"])
}

@Test func latestRunLooksAtTheGivenDeviceOnly() {
    let records: [Record] = [finalized(1), finalized(2, device: "mac2"), finalized(3)]
    #expect(FinalizedRuns.latestRun(in: records, device: "mac1") == 3)
    #expect(FinalizedRuns.latestRun(in: records, device: "mac2") == 2)
    #expect(FinalizedRuns.latestRun(in: records, device: "mac3") == nil)
}

@Test func speakerLabelNumbersOnlyFinalSpeakerIds() {
    #expect(SpeakerLabel.defaultName(for: "s3") == "話者3")
    #expect(SpeakerLabel.defaultName(for: "s12") == "話者12")
    #expect(SpeakerLabel.defaultName(for: "g1") == "g1")
    #expect(SpeakerLabel.defaultName(for: "s") == "s")
    #expect(SpeakerLabel.defaultName(for: "sx") == "sx")
}

@Test func newRecordsRoundTripThroughNDJSON() throws {
    let records: [Record] = [
        .sessionEnd(SessionEndRecord(ended: 1_791_000_000_000)),
        finalized(2),
        .speakerMerge(SpeakerMergeRecord(run: 2, from: "s3", into: "s1")),
        .speakerName(SpeakerNameRecord(speaker: "s1", name: "山田太郎", run: 2)),
        segment(start: 0, text: "確定", speaker: "s1", pass: .final, run: 2),
    ]
    for record in records {
        #expect(try NDJSON.decode(try NDJSON.encode(record)) == record)
    }
    #expect(
        try NDJSON.encode(finalized(1))
            == #"{"device":"mac1","run":1,"sources":["mic","system"],"t":"finalized"}"#)
    #expect(try NDJSON.encode(records[0]) == #"{"ended":1791000000000,"t":"session_end"}"#)
    #expect(
        try NDJSON.encode(records[2]) == #"{"from":"s3","into":"s1","run":2,"t":"speaker_merge"}"#)
    #expect(
        try NDJSON.encode(.speakerName(SpeakerNameRecord(speaker: "g1", name: "山田太郎")))
            == #"{"name":"山田太郎","speaker":"g1","t":"speaker_name"}"#)
}

@Test func finalSegmentLineCarriesPassRunAndSpeakerTag() throws {
    let record = segment(start: 0, text: "確定", speaker: "s1", pass: .final, run: 2)
    let line = try NDJSON.encode(record)
    #expect(line.contains(#""pass":"final""#))
    #expect(line.contains(#""run":2"#))
    #expect(!line.contains("embedding"))
    guard case .segment(let decoded) = try NDJSON.decode(line) else {
        Issue.record("not a segment")
        return
    }
    #expect(decoded.pass == .final)
    #expect(decoded.run == 2)
}

@Test func provisionalSegmentLineHasNoPassOrRun() throws {
    let line = try NDJSON.encode(segment(start: 0, text: "暫定"))
    #expect(!line.contains("\"pass\""))
    #expect(!line.contains("\"run\""))
}
