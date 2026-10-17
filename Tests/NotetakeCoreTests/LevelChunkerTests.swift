import Foundation
import Testing
@testable import NotetakeCore

@Suite struct LevelChunkerTests {
    @Test func chunksAreComputedPerFixedSize() {
        let samples = [Float](repeating: 0.1, count: 1600) + [Float](repeating: 0, count: 1600)
        let series = LevelChunker.dbfsSeries(samples: samples, chunkSamples: 1600)
        #expect(series.count == 2)
        #expect(abs(series[0] - 20 * log10(0.1)) < 0.01)
        #expect(series[1] == -120)
    }

    @Test func aRemainderShorterThanAChunkIsNotReturned() {
        let samples = [Float](repeating: 0.1, count: 2500)
        #expect(LevelChunker.dbfsSeries(samples: samples, chunkSamples: 1600).count == 1)
    }

    @Test func emptyInputReturnsNothing() {
        #expect(LevelChunker.dbfsSeries(samples: [], chunkSamples: 1600).isEmpty)
    }
}
