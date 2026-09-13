import Foundation
import Testing

@testable import NotetakeCore

@Test func singleSpeakerOnePiece() {
    var aligner = Aligner()
    let turn = SpeakerTurn(localID: "a", startMS: 0, endMS: 2000, embedding: [1, 0])
    aligner.add(turns: [turn], coveredUntilMS: 2000)
    aligner.add(piece: AlignerInput(text: "hello", startMS: 0, endMS: 2000))

    let result = aligner.drain(nowMS: 2000)

    #expect(result.count == 1)
    #expect(result[0].text == "hello")
    #expect(result[0].startMS == 0)
    #expect(result[0].endMS == 2000)
    #expect(result[0].localSpeaker == "a")
    #expect(result[0].embedding == [1, 0])
}

@Test func twoTurnsSplitAtRunBoundaryWithTextJoin() {
    var aligner = Aligner()
    let turns = [
        SpeakerTurn(localID: "a", startMS: 0, endMS: 1000, embedding: [1, 0]),
        SpeakerTurn(localID: "b", startMS: 1000, endMS: 2000, embedding: [0, 1]),
    ]
    aligner.add(turns: turns, coveredUntilMS: 2000)
    let runs = [
        TranscriptRun(text: "Hello ", startMS: 0, endMS: 1000),
        TranscriptRun(text: "World", startMS: 1000, endMS: 2000),
    ]
    aligner.add(piece: AlignerInput(text: "Hello World", startMS: 0, endMS: 2000, runs: runs))

    let result = aligner.drain(nowMS: 2000)

    #expect(result.count == 2)
    #expect(result[0].text == "Hello ")
    #expect(result[0].localSpeaker == "a")
    #expect(result[0].embedding == [1, 0])
    #expect(result[1].text == "World")
    #expect(result[1].localSpeaker == "b")
    #expect(result[1].embedding == [0, 1])
}

@Test func uncoveredPieceStaysPendingThenEmittedAfterCoverage() {
    var aligner = Aligner()
    aligner.add(piece: AlignerInput(text: "hello", startMS: 0, endMS: 2000))

    // Not covered yet and well within the hold limit: nothing should come out.
    let firstDrain = aligner.drain(nowMS: 2000)
    #expect(firstDrain.isEmpty)

    aligner.add(
        turns: [SpeakerTurn(localID: "a", startMS: 0, endMS: 2000, embedding: [1, 0])],
        coveredUntilMS: 2000)

    let secondDrain = aligner.drain(nowMS: 2000)
    #expect(secondDrain.count == 1)
    #expect(secondDrain[0].text == "hello")
    #expect(secondDrain[0].localSpeaker == "a")
}

@Test func holdLimitExpiryEmitsWithNilSpeaker() {
    var config = Aligner.Config()
    config.holdLimitMS = 1000
    var aligner = Aligner(config: config)
    aligner.add(piece: AlignerInput(text: "hello", startMS: 0, endMS: 2000))

    // 2500 - 2000 = 500 <= holdLimitMS: still waiting.
    let tooEarly = aligner.drain(nowMS: 2500)
    #expect(tooEarly.isEmpty)

    // 3100 - 2000 = 1100 > holdLimitMS: emit even though never covered.
    let expired = aligner.drain(nowMS: 3100)
    #expect(expired.count == 1)
    #expect(expired[0].text == "hello")
    #expect(expired[0].localSpeaker == nil)
    #expect(expired[0].embedding == nil)
}

@Test func flushEmitsEverything() {
    var aligner = Aligner()
    aligner.add(piece: AlignerInput(text: "one", startMS: 0, endMS: 1000))
    aligner.add(piece: AlignerInput(text: "two", startMS: 1000, endMS: 2000))

    let result = aligner.flush()

    #expect(result.map(\.text) == ["one", "two"])
    #expect(result.allSatisfy { $0.localSpeaker == nil })

    // pending was drained by the flush, so a second flush is empty.
    #expect(aligner.flush().isEmpty)
}

@Test func runWithoutOverlapInheritsPreviousSpeaker() {
    var aligner = Aligner()
    let turns = [
        SpeakerTurn(localID: "a", startMS: 0, endMS: 1000, embedding: [1, 0]),
        SpeakerTurn(localID: "c", startMS: 1100, endMS: 2000, embedding: [0, 1]),
    ]
    aligner.add(turns: turns, coveredUntilMS: 2000)
    let runs = [
        TranscriptRun(text: "A", startMS: 0, endMS: 1000),
        TranscriptRun(text: "B", startMS: 1000, endMS: 1100),  // gap: no turn overlaps this run
        TranscriptRun(text: "C", startMS: 1100, endMS: 2000),
    ]
    aligner.add(piece: AlignerInput(text: "ABC", startMS: 0, endMS: 2000, runs: runs))

    let result = aligner.drain(nowMS: 2000)

    #expect(result.count == 2)
    #expect(result[0].text == "AB")
    #expect(result[0].localSpeaker == "a")
    #expect(result[1].text == "C")
    #expect(result[1].localSpeaker == "c")
}

@Test func leadingRunWithoutOverlapTakesFirstLaterSpeaker() {
    var aligner = Aligner()
    let turns = [
        SpeakerTurn(localID: "a", startMS: 100, endMS: 1000, embedding: [1, 0])
    ]
    aligner.add(turns: turns, coveredUntilMS: 1000)
    let runs = [
        TranscriptRun(text: "lead", startMS: 0, endMS: 100),  // before any turn starts
        TranscriptRun(text: "rest", startMS: 100, endMS: 1000),
    ]
    aligner.add(piece: AlignerInput(text: "leadrest", startMS: 0, endMS: 1000, runs: runs))

    let result = aligner.drain(nowMS: 1000)

    #expect(result.count == 1)
    #expect(result[0].text == "leadrest")
    #expect(result[0].localSpeaker == "a")
}

@Test func emptyRunsPieceUsesWholePieceRange() {
    var aligner = Aligner()
    aligner.add(
        turns: [SpeakerTurn(localID: "a", startMS: 0, endMS: 1000, embedding: [1, 0])],
        coveredUntilMS: 1000)
    aligner.add(piece: AlignerInput(text: "hello", startMS: 0, endMS: 1000))

    let result = aligner.drain(nowMS: 1000)

    #expect(result.count == 1)
    #expect(result[0].text == "hello")
    #expect(result[0].startMS == 0)
    #expect(result[0].endMS == 1000)
    #expect(result[0].localSpeaker == "a")
}

@Test func emptyRunsPieceWithNoTurnsGetsNilSpeaker() {
    var aligner = Aligner()
    aligner.add(piece: AlignerInput(text: "hello", startMS: 0, endMS: 1000))

    let result = aligner.flush()

    #expect(result.count == 1)
    #expect(result[0].text == "hello")
    #expect(result[0].localSpeaker == nil)
    #expect(result[0].embedding == nil)
}

@Test func emptyTextPieceIsDropped() {
    var aligner = Aligner()
    aligner.add(piece: AlignerInput(text: "", startMS: 0, endMS: 1000))
    aligner.add(piece: AlignerInput(text: "kept", startMS: 1000, endMS: 2000))

    let result = aligner.flush()

    #expect(result.map(\.text) == ["kept"])
}

@Test func orderPreserved() {
    var aligner = Aligner()
    // Arrival order is "first" then "second", even though "second"'s time range
    // is earlier and becomes coverable first.
    aligner.add(piece: AlignerInput(text: "first", startMS: 1000, endMS: 2000))
    aligner.add(piece: AlignerInput(text: "second", startMS: 0, endMS: 1000))

    aligner.add(
        turns: [SpeakerTurn(localID: "a", startMS: 0, endMS: 1000, embedding: [1, 0])],
        coveredUntilMS: 1000)

    // "second" is covered but "first" (arrived earlier, still pending) blocks the scan.
    let blocked = aligner.drain(nowMS: 1000)
    #expect(blocked.isEmpty)

    aligner.add(
        turns: [SpeakerTurn(localID: "b", startMS: 1000, endMS: 2000, embedding: [0, 1])],
        coveredUntilMS: 2000)

    let drained = aligner.drain(nowMS: 2000)
    #expect(drained.map(\.text) == ["first", "second"])
}
