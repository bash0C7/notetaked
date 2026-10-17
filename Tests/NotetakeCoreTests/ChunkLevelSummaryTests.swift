import Foundation
import Testing
@testable import NotetakeCore

@Test func emptySummaryHasNoValues() {
    let summary = ChunkLevelSummary()
    #expect(summary.maxDBFS == nil)
    #expect(summary.meanDBFS == nil)
}

@Test func summaryTracksMaxAndMean() {
    var summary = ChunkLevelSummary()
    summary.add(dbfs: -60)
    summary.add(dbfs: -40)
    summary.add(dbfs: -20)
    #expect(summary.maxDBFS == -20)
    #expect(summary.meanDBFS == -40)
}

@Test func silenceStaysAtMinus120() {
    var summary = ChunkLevelSummary()
    summary.add(dbfs: -120)
    #expect(summary.maxDBFS == -120)
}

@Test func resetClearsTheValues() {
    var summary = ChunkLevelSummary()
    summary.add(dbfs: -30)
    summary.reset()
    #expect(summary.maxDBFS == nil)
    #expect(summary.meanDBFS == nil)
}

@Test func nonFiniteAndOutOfRangeValuesAreClamped() {
    var nan = ChunkLevelSummary()
    nan.add(dbfs: .nan)
    #expect(nan.maxDBFS == -120)
    #expect(nan.meanDBFS == -120)

    var negInf = ChunkLevelSummary()
    negInf.add(dbfs: -.infinity)
    #expect(negInf.maxDBFS == -120)
    #expect(negInf.meanDBFS == -120)

    var posInf = ChunkLevelSummary()
    posInf.add(dbfs: .infinity)
    #expect(posInf.maxDBFS == 0)
    #expect(posInf.meanDBFS == 0)

    var low = ChunkLevelSummary()
    low.add(dbfs: -500)
    #expect(low.maxDBFS == -120)

    var high = ChunkLevelSummary()
    high.add(dbfs: 5)
    #expect(high.maxDBFS == 0)
    #expect(high.meanDBFS == 0)
}
