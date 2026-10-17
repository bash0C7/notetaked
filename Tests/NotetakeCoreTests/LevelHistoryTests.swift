import Testing
@testable import NotetakeCore

@Suite struct LevelHistoryTests {
    @Test func appendKeepsOldestFirstAndDropsSamplesOlderThanTheWindow() {
        var history = LevelHistory(windowMS: 10_000)
        history.append(atMS: 0, dbfs: -50)
        history.append(atMS: 4_000, dbfs: -50)
        history.append(atMS: 12_000, dbfs: -50)
        #expect(history.samples.map(\.atMS) == [4_000, 12_000])
    }

    @Test func trailingSilenceCountsConsecutiveSilentMeasuredSamples() {
        var history = LevelHistory()
        for atMS in stride(from: Int64(1_000), through: 4_400, by: 100) {
            history.append(atMS: atMS, dbfs: -120.0)
        }
        #expect(history.trailingSilenceMS(nowMS: 4_500) == 3_500)
    }

    @Test func aGapResetsTheSilenceRun() {
        var history = LevelHistory()
        for atMS in stride(from: Int64(0), to: 3_000, by: 100) {
            history.append(atMS: atMS, dbfs: -120.0)
        }
        history.appendGap(atMS: 3_000)
        for atMS in stride(from: Int64(3_100), to: 4_100, by: 100) {
            history.append(atMS: atMS, dbfs: -120.0)
        }
        #expect(history.trailingSilenceMS(nowMS: 4_100) == 1_000)
    }

    @Test func aGapAtTheTailIsNotSilence() {
        var history = LevelHistory()
        for atMS in stride(from: Int64(0), to: 3_000, by: 100) {
            history.append(atMS: atMS, dbfs: -120.0)
        }
        history.appendGap(atMS: 3_000)
        #expect(history.trailingSilenceMS(nowMS: 3_100) == 0)
    }

    @Test func aQuietRoomIsNotSilence() {
        var history = LevelHistory()
        for atMS in stride(from: Int64(0), to: 5_000, by: 100) {
            history.append(atMS: atMS, dbfs: -70.0)
        }
        #expect(history.trailingSilenceMS(nowMS: 5_000) == 0)
    }

    @Test func soundAboveThresholdOnlyCountsSinceTheGivenTime() {
        var history = LevelHistory()
        history.append(atMS: 1_000, dbfs: -30.0)
        history.append(atMS: 2_000, dbfs: -90.0)
        #expect(history.hasSound(above: -50, sinceMS: 0) == true)
        #expect(history.hasSound(above: -50, sinceMS: 1_500) == false)
    }

    @Test func theWindowNeverGrowsBeyondItsLength() {
        var history = LevelHistory(windowMS: 90_000)
        for atMS in stride(from: Int64(0), through: 100_000, by: 100) {
            history.append(atMS: atMS, dbfs: -50)
            #expect(history.samples.count <= 901)
        }
    }
}
