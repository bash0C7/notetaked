import Foundation
import Testing
@testable import NotetakeCore

private func run(_ text: String, _ start: Int64, _ end: Int64) -> TranscriptRun {
    TranscriptRun(text: text, startMS: start, endMS: end)
}

private func phrase(_ runs: [TranscriptRun], confidence: Double? = nil) -> TranscribedPhrase {
    TranscribedPhrase(runs: runs, confidence: confidence)
}

@Test func runTakesTheSpeakerWithTheLargestOverlap() {
    let turns = [
        SpeakerTurn(speaker: "S1", startMS: 0, endMS: 3_000),
        SpeakerTurn(speaker: "S2", startMS: 3_000, endMS: 9_000),
    ]
    let result = SpeakerAssigner.assign(
        phrases: [phrase([run("こんにちは", 2_000, 5_000)])], turns: turns)
    #expect(result.map(\.speaker) == ["S2"])
}

@Test func runWithoutOverlapTakesTheNearestTurn() {
    let turns = [
        SpeakerTurn(speaker: "S1", startMS: 0, endMS: 1_000),
        SpeakerTurn(speaker: "S2", startMS: 9_000, endMS: 10_000),
    ]
    let result = SpeakerAssigner.assign(
        phrases: [
            phrase([run("近い", 2_000, 3_000)]),
            phrase([run("遠い", 7_000, 8_000)]),
            phrase([run("前", -500, -100)]),
            phrase([run("後", 12_000, 13_000)]),
        ], turns: turns)
    #expect(result.map(\.speaker) == ["S1", "S2", "S1", "S2"])
}

@Test func zeroLengthRunInsideATurnTakesThatTurn() {
    let turns = [
        SpeakerTurn(speaker: "S1", startMS: 0, endMS: 5_000),
        SpeakerTurn(speaker: "S2", startMS: 5_000, endMS: 10_000),
    ]
    let result = SpeakerAssigner.assign(phrases: [phrase([run("はい", 7_000, 7_000)])], turns: turns)
    #expect(result.map(\.speaker) == ["S2"])
}

@Test func speakerChangeInsideAPhraseSplitsTheUtterance() {
    let turns = [
        SpeakerTurn(speaker: "S1", startMS: 0, endMS: 2_000),
        SpeakerTurn(speaker: "S2", startMS: 2_000, endMS: 6_000),
    ]
    let phrases = [
        phrase(
            [run("今日は", 0, 800), run("晴れ", 800, 1_800), run("ですね", 2_100, 3_000), run("そうですね", 3_000, 4_500)],
            confidence: 0.9)
    ]
    let result = SpeakerAssigner.assign(phrases: phrases, turns: turns)
    #expect(
        result == [
            AssignedUtterance(speaker: "S1", text: "今日は晴れ", startMS: 0, endMS: 1_800, confidence: 0.9),
            AssignedUtterance(speaker: "S2", text: "ですねそうですね", startMS: 2_100, endMS: 4_500, confidence: 0.9),
        ])
}

@Test func sameSpeakerIsNotJoinedAcrossPhrases() {
    let turns = [SpeakerTurn(speaker: "S1", startMS: 0, endMS: 20_000)]
    let result = SpeakerAssigner.assign(
        phrases: [phrase([run("一つ目", 0, 1_000)]), phrase([run("二つ目", 5_000, 6_000)])], turns: turns)
    #expect(result.map(\.text) == ["一つ目", "二つ目"])
}

@Test func withoutTurnsTheSpeakerIsNil() {
    let result = SpeakerAssigner.assign(phrases: [phrase([run("発話", 0, 1_000)])], turns: [])
    #expect(result.map(\.speaker) == [nil])
}

@Test func blankPhrasesProduceNoUtterance() {
    let turns = [SpeakerTurn(speaker: "S1", startMS: 0, endMS: 5_000)]
    let result = SpeakerAssigner.assign(
        phrases: [phrase([run(" ", 0, 500)]), phrase([run(" 本文 ", 1_000, 2_000)])], turns: turns)
    #expect(result.map(\.text) == ["本文"])
}

@Test func unsortedTurnsAreHandled() {
    let turns = [
        SpeakerTurn(speaker: "S2", startMS: 5_000, endMS: 10_000),
        SpeakerTurn(speaker: "S1", startMS: 0, endMS: 5_000),
    ]
    let result = SpeakerAssigner.assign(
        phrases: [phrase([run("前半", 1_000, 2_000)]), phrase([run("後半", 6_000, 7_000)])], turns: turns)
    #expect(result.map(\.speaker) == ["S1", "S2"])
}

@Test func speakersAreNumberedByFirstSpokenAcrossSources() {
    let ids = SpeakerNumbering.assign(firstSpoken: [
        LocalSpeaker(source: .mic, id: "S1"): 5_000,
        LocalSpeaker(source: .system, id: "S1"): 1_000,
        LocalSpeaker(source: .mic, id: "S2"): 9_000,
        LocalSpeaker(source: .system, id: "S2"): 5_000,
    ])
    #expect(ids[LocalSpeaker(source: .system, id: "S1")] == "s1")
    #expect(ids[LocalSpeaker(source: .mic, id: "S1")] == "s2")
    #expect(ids[LocalSpeaker(source: .system, id: "S2")] == "s3")
    #expect(ids[LocalSpeaker(source: .mic, id: "S2")] == "s4")
    #expect(LocalSpeaker(source: .mic, id: "S1").tag == "mic:S1")
}

@Test func cosineSimilarityHandlesDegenerateVectors() {
    #expect(abs(VoiceSimilarity.cosine([1, 0], [1, 0]) - 1) < 1e-9)
    #expect(abs(VoiceSimilarity.cosine([1, 0], [0, 1])) < 1e-9)
    #expect(abs(VoiceSimilarity.cosine([1, 0], [-1, 0]) + 1) < 1e-9)
    #expect(VoiceSimilarity.cosine([1, 0], [1, 0, 0]) == 0)
    #expect(VoiceSimilarity.cosine([], []) == 0)
    #expect(VoiceSimilarity.cosine([0, 0], [1, 0]) == 0)
}

@Test func matcherUsesOnlyPairsAtOrAboveTheThreshold() {
    let previous = ["s1": [Float](arrayLiteral: 1, 0)]
    let close = ["s1": [Float](arrayLiteral: 0.8, 0.6)]  // cosine 0.8
    let far = ["s1": [Float](arrayLiteral: 0.6, 0.8)]  // cosine 0.6
    #expect(SpeakerMatcher.threshold == 0.7)
    #expect(SpeakerMatcher.match(current: close, previous: previous).map(\.previous) == ["s1"])
    #expect(SpeakerMatcher.match(current: far, previous: previous).isEmpty)
}

@Test func matcherPairsOneToOneInDescendingSimilarity() {
    let previous: [String: [Float]] = ["s1": [1, 0]]
    let current: [String: [Float]] = ["s1": [0.8, 0.6], "s2": [0.95, 0.31]]
    let matches = SpeakerMatcher.match(current: current, previous: previous)
    #expect(matches.map(\.current) == ["s2"])
    #expect(matches.map(\.previous) == ["s1"])
}

@Test func matcherReportsTheClosestPreviousSpeakerPerCurrentSpeaker() {
    let previous: [String: [Float]] = ["s1": [1, 0], "s2": [0, 1]]
    let current: [String: [Float]] = ["s1": [0.6, 0.8], "s2": [0.1, 0.99]]
    let closest = SpeakerMatcher.closest(current: current, previous: previous)
    #expect(closest.map(\.current) == ["s1", "s2"])
    #expect(closest.map(\.previous) == ["s2", "s2"])
}
