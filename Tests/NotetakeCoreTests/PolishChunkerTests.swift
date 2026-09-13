import Foundation
import Testing
@testable import NotetakeCore

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

// MARK: - turns(from:)

@Test func turnsFromUtterancesMergeConsecutiveSpeakersAndSkipEmpty() {
    let a1 = utterance(start: 0, speaker: "小芝", text: "こんにちは")
    let aEmpty = utterance(start: 500, speaker: "小芝", text: "")
    let a2 = utterance(start: 1000, speaker: "小芝", text: "、元気ですか")
    let b = utterance(start: 2000, speaker: "田中", text: "うん")

    let turns = PolishChunker.turns(from: [a1, aEmpty, a2, b])

    #expect(turns == [
        PolishTurn(speaker: "小芝", text: "こんにちは、元気ですか", startMS: 0),
        PolishTurn(speaker: "田中", text: "うん", startMS: 2000),
    ])
}

@Test func turnsDoNotMergeNonConsecutiveSameSpeaker() {
    let a1 = utterance(start: 0, speaker: "A", text: "1")
    let b = utterance(start: 100, speaker: "B", text: "2")
    let a2 = utterance(start: 200, speaker: "A", text: "3")

    let turns = PolishChunker.turns(from: [a1, b, a2])

    #expect(turns == [
        PolishTurn(speaker: "A", text: "1", startMS: 0),
        PolishTurn(speaker: "B", text: "2", startMS: 100),
        PolishTurn(speaker: "A", text: "3", startMS: 200),
    ])
}

@Test func turnsFromEmptyUtterancesIsEmpty() {
    #expect(PolishChunker.turns(from: []) == [])
}

// MARK: - chunks

@Test func chunksSplitByMaxCharacters() {
    let turns = [
        PolishTurn(speaker: "A", text: String(repeating: "あ", count: 5), startMS: 0),
        PolishTurn(speaker: "B", text: String(repeating: "い", count: 5), startMS: 1000),
        PolishTurn(speaker: "A", text: String(repeating: "う", count: 5), startMS: 2000),
    ]

    let chunks = PolishChunker.chunks(turns, maxCharacters: 12, contextTurns: 2)

    #expect(chunks.count == 2)
    #expect(chunks[0].body == [turns[0], turns[1]])
    #expect(chunks[1].body == [turns[2]])
}

@Test func oversizedSingleTurnGetsItsOwnChunk() {
    let big = PolishTurn(speaker: "A", text: String(repeating: "あ", count: 20), startMS: 0)
    let small = PolishTurn(speaker: "B", text: "うん", startMS: 1000)

    let chunks = PolishChunker.chunks([big, small], maxCharacters: 10, contextTurns: 2)

    #expect(chunks.count == 2)
    #expect(chunks[0].body == [big])
    #expect(chunks[1].body == [small])
}

@Test func chunkContextIsPreviousChunkBodyTail() {
    let turns = (1...5).map { PolishTurn(speaker: "A", text: "x", startMS: Int64($0) * 100) }

    // 1文字ずつ: maxCharacters=3で最初の3件が1 chunk、残り2件が次のchunkになる
    let chunks = PolishChunker.chunks(turns, maxCharacters: 3, contextTurns: 2)

    #expect(chunks.count == 2)
    #expect(chunks[0].body == Array(turns[0..<3]))
    #expect(chunks[0].context == [])
    #expect(chunks[1].body == Array(turns[3..<5]))
    #expect(chunks[1].context == Array(turns[1..<3]))
}

@Test func chunksOfEmptyTurnsIsEmpty() {
    #expect(PolishChunker.chunks([]) == [])
}

// MARK: - merge

@Test func mergeExactCountAssignsStartMSAndPolishedTrue() {
    let body = [
        PolishTurn(speaker: "小芝", text: "こんにちは", startMS: 0),
        PolishTurn(speaker: "田中", text: "うん", startMS: 1000),
    ]
    let chunk = PolishChunk(context: [], body: body)
    let output: [(speaker: String, text: String)]? = [
        (speaker: "小芝", text: "こんにちは。"),
        (speaker: "田中", text: "うん。"),
    ]

    let result = PolishChunker.merge(outputs: [output], chunks: [chunk])

    #expect(result == [
        PolishedTurn(speaker: "小芝", text: "こんにちは。", startMS: 0, polished: true),
        PolishedTurn(speaker: "田中", text: "うん。", startMS: 1000, polished: true),
    ])
}

@Test func mergeCountMismatchAssignsNilStartMS() {
    let body = [
        PolishTurn(speaker: "小芝", text: "こんにちは", startMS: 0),
        PolishTurn(speaker: "田中", text: "うん", startMS: 1000),
    ]
    let chunk = PolishChunk(context: [], body: body)
    let output: [(speaker: String, text: String)]? = [
        (speaker: "小芝", text: "こんにちは、田中さん。うん、元気です。"),
    ]

    let result = PolishChunker.merge(outputs: [output], chunks: [chunk])

    #expect(result == [
        PolishedTurn(speaker: "小芝", text: "こんにちは、田中さん。うん、元気です。", startMS: nil, polished: true),
    ])
}

@Test func mergeNilOutputFallsBackToOriginalPolishedFalse() {
    let body = [
        PolishTurn(speaker: "小芝", text: "こんにちは", startMS: 0),
    ]
    let chunk = PolishChunk(context: [], body: body)

    let result = PolishChunker.merge(outputs: [nil], chunks: [chunk])

    #expect(result == [
        PolishedTurn(speaker: "小芝", text: "こんにちは", startMS: 0, polished: false),
    ])
}

@Test func mergeEmptyOutputFallsBackToOriginalPolishedFalse() {
    let body = [PolishTurn(speaker: "A", text: "hi", startMS: 0)]
    let chunk = PolishChunk(context: [], body: body)
    let emptyOutput: [(speaker: String, text: String)]? = []

    let result = PolishChunker.merge(outputs: [emptyOutput], chunks: [chunk])

    #expect(result == [PolishedTurn(speaker: "A", text: "hi", startMS: 0, polished: false)])
}

@Test func mergeAcrossMultipleChunksPreservesTotalCount() {
    let chunk0 = PolishChunk(context: [], body: [
        PolishTurn(speaker: "A", text: "a", startMS: 0),
        PolishTurn(speaker: "B", text: "b", startMS: 100),
    ])
    let chunk1 = PolishChunk(context: [], body: [
        PolishTurn(speaker: "A", text: "c", startMS: 200),
    ])

    let result = PolishChunker.merge(
        outputs: [
            [(speaker: "A", text: "a."), (speaker: "B", text: "b.")],
            nil,
        ],
        chunks: [chunk0, chunk1]
    )

    #expect(result.count == 3)
    #expect(result[0] == PolishedTurn(speaker: "A", text: "a.", startMS: 0, polished: true))
    #expect(result[1] == PolishedTurn(speaker: "B", text: "b.", startMS: 100, polished: true))
    #expect(result[2] == PolishedTurn(speaker: "A", text: "c", startMS: 200, polished: false))
}
