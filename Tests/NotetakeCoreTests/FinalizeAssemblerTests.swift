import Foundation
import Testing
@testable import NotetakeCore

private let usb = InputDevice(name: "外部マイク", uid: "external", spatial: false)

/// sample 0が1_000_000ms、10秒の音声の後に10秒の途切れ（sample 160_000が1_020_000ms）
private func timeline() -> CaptureTimeline {
    CaptureTimeline(lines: [
        .anchor(CaptureAnchor(sample: 0, ms: 1_000_000)),
        .device(sample: 0, device: .test),
        .anchor(CaptureAnchor(sample: 160_000, ms: 1_020_000)),
        .device(sample: 160_000, device: usb),
    ])
}

private func phrase(_ text: String, _ start: Int64, _ end: Int64) -> TranscribedPhrase {
    TranscribedPhrase(runs: [TranscriptRun(text: text, startMS: start, endMS: end)], confidence: 0.8)
}

@Test func assemblerConvertsTimesAcrossAGapAndFollowsTheDevice() throws {
    let result = try FinalizeAssembler.sourceResult(
        source: .mic,
        phrases: [phrase("途切れの前", 2_000, 3_000), phrase("途切れの後", 11_000, 12_500)],
        turns: [
            SpeakerTurn(speaker: "S1", startMS: 0, endMS: 10_000),
            SpeakerTurn(speaker: "S2", startMS: 10_000, endMS: 14_000),
        ],
        centroids: ["S1": [1, 0], "S2": [0, 1]],
        timeline: timeline(), levelDBFS: { Double($0.count) }, fallbackInput: usb)

    #expect(result.utterances.map(\.start) == [1_002_000, 1_021_000])
    #expect(result.utterances.map(\.end) == [1_003_000, 1_022_500])
    #expect(result.utterances.map(\.input) == [.test, usb])
    #expect(result.utterances.map(\.speaker) == ["S1", "S2"])
    #expect(result.utterances[0].levelDBFS == 16_000)
    #expect(result.utterances[0].confidence == 0.8)
    #expect(result.speakers.map(\.local) == ["S1", "S2"])
    #expect(result.speakers.map(\.seconds) == [10, 4])
    #expect(result.speakers.map(\.centroid) == [[1, 0], [0, 1]])
    #expect(result.speakers[1].firstStartMS == 1_021_000)
    #expect(result.speakers[0].excerpt == "途切れの前")
}

@Test func systemUsesTheSystemInputAndDeviceLessMicUsesTheFallback() throws {
    let phrases = [phrase("発話", 1_000, 2_000)]
    let anchorOnly = CaptureTimeline(lines: [.anchor(CaptureAnchor(sample: 0, ms: 5_000))])
    let system = try FinalizeAssembler.sourceResult(
        source: .system, phrases: phrases, turns: [], centroids: [:], timeline: timeline(),
        levelDBFS: { _ in -30 }, fallbackInput: usb)
    #expect(system.utterances.map(\.input) == [.system])
    #expect(system.utterances.map(\.speaker) == [nil])
    #expect(system.speakers.isEmpty)

    let mic = try FinalizeAssembler.sourceResult(
        source: .mic, phrases: phrases, turns: [], centroids: [:], timeline: anchorOnly,
        levelDBFS: { _ in -30 }, fallbackInput: usb)
    #expect(mic.utterances.map(\.input) == [usb])
}

@Test func assemblerFailsWithoutAnAnchor() {
    #expect(throws: FinalizeAssemblyError.noAnchor(.mic)) {
        _ = try FinalizeAssembler.sourceResult(
            source: .mic, phrases: [phrase("発話", 0, 1_000)], turns: [], centroids: [:],
            timeline: CaptureTimeline(), levelDBFS: { _ in 0 }, fallbackInput: usb)
    }
}

@Test func assemblerTruncatesTheExcerpt() throws {
    let long = String(repeating: "あ", count: 100)
    let result = try FinalizeAssembler.sourceResult(
        source: .mic, phrases: [phrase(long, 0, 1_000)], turns: [SpeakerTurn(speaker: "S1", startMS: 0, endMS: 1_000)],
        centroids: [:], timeline: timeline(), levelDBFS: { _ in 0 }, fallbackInput: usb)
    #expect(result.speakers[0].excerpt.count == FinalizeAssembler.excerptLength)
    #expect(result.speakers[0].centroid.isEmpty)
}

@Test func finalizeResultRoundTrips() throws {
    let utterance = FinalizeUtterance(
        id: UUID(), speaker: "S1", start: 1, end: 2, text: "発話", confidence: nil, levelDBFS: -20, input: .test)
    let result = FinalizeResult(
        run: 3,
        sources: [
            FinalizeSourceResult(
                source: .mic, utterances: [utterance],
                speakers: [FinalizeSpeaker(local: "S1", seconds: 1.5, excerpt: "発話", firstStartMS: 1, centroid: [0.5])])
        ])
    let data = try JSONEncoder().encode(result)
    #expect(try JSONDecoder().decode(FinalizeResult.self, from: data) == result)
    #expect(String(decoding: data, as: UTF8.self).contains("\"level_dbfs\""))
}

@Test func ownerLabelFollowsTheSource() {
    #expect(OwnerLabel.label(for: .mic, configuredOwner: "山田太郎") == "山田太郎")
    #expect(OwnerLabel.label(for: .system, configuredOwner: "山田太郎") == "リモート")
}

@Test func finalizePathsLiveInTheRawAudioDirectory() {
    let directory = URL(fileURLWithPath: "/tmp/raw/p")
    #expect(CaptureSessionPaths.finalizeResultURL(sessionDirectory: directory).path == "/tmp/raw/p/finalize.json")
    #expect(CaptureSessionPaths.finalizeAttemptsURL(sessionDirectory: directory).path == "/tmp/raw/p/finalize-attempts")
}
