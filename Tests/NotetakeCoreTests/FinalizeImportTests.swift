import Foundation
import Testing
@testable import NotetakeCore

private let info = CaptureSessionInfo(
    outputDirectory: "/tmp/out", device: "mac1", deviceName: "山田太郎のMac", owner: "山田太郎")

private func utterance(_ speaker: String?, _ start: Int64, _ text: String) -> FinalizeUtterance {
    FinalizeUtterance(
        id: UUID(), speaker: speaker, start: start, end: start + 1_000, text: text, confidence: 0.9,
        levelDBFS: -25, input: .test)
}

private func speaker(_ local: String, first: Int64, centroid: [Float], seconds: Double = 10) -> FinalizeSpeaker {
    FinalizeSpeaker(local: local, seconds: seconds, excerpt: "抜粋", firstStartMS: first, centroid: centroid)
}

private func result(run: Int = 1) -> FinalizeResult {
    FinalizeResult(
        run: run,
        sources: [
            FinalizeSourceResult(
                source: .mic,
                utterances: [utterance("S1", 5_000, "マイクの発話"), utterance("S2", 9_000, "二人目")],
                speakers: [speaker("S1", first: 5_000, centroid: [1, 0]), speaker("S2", first: 9_000, centroid: [0, 1])]),
            FinalizeSourceResult(
                source: .system,
                utterances: [utterance("S1", 1_000, "リモートの発話"), utterance(nil, 20_000, "話者なし")],
                speakers: [speaker("S1", first: 1_000, centroid: [0.6, 0.8])]),
        ])
}

@Test func importPlanNumbersSpeakersByFirstSpokenAndBuildsFinalSegments() throws {
    let plan = FinalizeImport.plan(
        result: result(), info: info, prefix: "2026-10-06_100000", previous: nil, receivedAt: 7)

    #expect(plan.speakers.run == 1)
    #expect(plan.speakers.speakers.map(\.id) == ["s1", "s2", "s3"])
    #expect(plan.speakers.speakers.map(\.source) == [.system, .mic, .mic])

    let segments = plan.records.compactMap { record -> Segment? in
        if case .segment(let segment) = record { return segment }
        return nil
    }
    #expect(segments.map(\.text) == ["リモートの発話", "マイクの発話", "二人目", "話者なし"])
    #expect(segments.map(\.seq) == [1, 2, 3, 4])
    #expect(segments.map(\.owner) == ["リモート", "山田太郎", "山田太郎", "リモート"])
    #expect(segments.allSatisfy { $0.pass == .final && $0.run == 1 && $0.device == "mac1" && $0.session == "2026-10-06_100000" })
    #expect(segments[0].speaker == SpeakerTag(local: "system:S1", global: "s1"))
    #expect(segments[1].speaker == SpeakerTag(local: "mic:S1", global: "s2"))
    #expect(segments[3].speaker == nil)
    #expect(segments.allSatisfy { $0.speaker?.embedding == nil })

    guard case .finalized(let finalized)? = plan.records.last else {
        Issue.record("the last record must be finalized")
        return
    }
    #expect(finalized == FinalizedRecord(run: 1, device: "mac1", sources: [.mic, .system]))
}

@Test func importedRecordsFoldIntoNumberedSpeakers() {
    let plan = FinalizeImport.plan(result: result(), info: info, prefix: "p", previous: nil, receivedAt: 0)
    let utterances = Reconciler.fold(plan.records)
    #expect(utterances.map(\.speaker) == ["話者1", "話者2", "話者3", "リモート"])
}

@Test func importCarriesNamesByVoiceSimilarity() {
    let previous = SpeakersFile(
        run: 1,
        speakers: [
            SpeakersFile.Speaker(
                id: "s1", source: .system, name: "佐藤花子", speechSeconds: 5, excerpt: "", firstStartMS: 0,
                centroid: [0.62, 0.78]),
            SpeakersFile.Speaker(
                id: "s2", source: .mic, name: nil, speechSeconds: 5, excerpt: "", firstStartMS: 0,
                centroid: [0, 1]),
            SpeakersFile.Speaker(
                id: "s3", source: .mic, name: "山田太郎", speechSeconds: 5, excerpt: "", firstStartMS: 0,
                centroid: [0.99, 0.1]),
        ])
    let plan = FinalizeImport.plan(
        result: result(run: 2), info: info, prefix: "p", previous: previous, receivedAt: 0)

    // 新しいs1（system S1 [0.6, 0.8]）は前回のs1、新しいs2（mic S1 [1, 0]）は前回のs3に近い。
    // 名前の無い前回のs2は、新しいs3（mic S2 [0, 1]）に近くても対象にならない
    #expect(plan.matches.map(\.current).sorted() == ["s1", "s2"])
    #expect(plan.speakers.speakers.map(\.name) == ["佐藤花子", "山田太郎", nil])
    let names = plan.records.compactMap { record -> SpeakerNameRecord? in
        if case .speakerName(let rename) = record { return rename }
        return nil
    }
    #expect(names.map(\.run) == [2, 2])
    #expect(plan.closest.map(\.current) == ["s3"])
}

@Test func importOfTheSameRunKeepsTheNamesOfThePreviousFile() {
    let first = FinalizeImport.plan(result: result(), info: info, prefix: "p", previous: nil, receivedAt: 0)
    var named = first.speakers
    named.speakers[0].name = "佐藤花子"
    let again = FinalizeImport.plan(result: result(), info: info, prefix: "p", previous: named, receivedAt: 0)
    #expect(again.speakers.speakers.map(\.name) == ["佐藤花子", nil, nil])
    #expect(again.matches.isEmpty)
}

@Test func importedRunIsDetected() {
    let plan = FinalizeImport.plan(result: result(run: 2), info: info, prefix: "p", previous: nil, receivedAt: 0)
    #expect(FinalizeImport.isImported(run: 2, in: plan.records))
    #expect(!FinalizeImport.isImported(run: 1, in: plan.records))
    #expect(!FinalizeImport.isImported(run: 2, in: []))
}

@Test func importingTheSameResultTwiceProducesTheSameRenderedTranscript() {
    let plan = FinalizeImport.plan(result: result(), info: info, prefix: "p", previous: nil, receivedAt: 0)
    let once = Reconciler.fold(plan.records)
    let twice = Reconciler.fold(plan.records + plan.records)
    #expect(once.map(\.text) == twice.map(\.text))
    #expect(once.count == 4)
}
