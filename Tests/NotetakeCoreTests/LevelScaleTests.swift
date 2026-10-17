import Testing
@testable import NotetakeCore

@Suite struct LevelScaleTests {
    @Test func normalizedAtTheFloorIsZero() {
        #expect(LevelScale.normalized(dbfs: -80) == 0)
    }

    @Test func normalizedAtZeroIsOne() {
        #expect(LevelScale.normalized(dbfs: 0) == 1)
    }

    @Test func normalizedInTheMiddleIsLinear() {
        #expect(LevelScale.normalized(dbfs: -40) == 0.5)
    }

    @Test func normalizedClampsAboveZeroAndBelowTheFloor() {
        #expect(LevelScale.normalized(dbfs: 6) == 1)
        #expect(LevelScale.normalized(dbfs: -120) == 0)
    }

    @Test func silentOnlyAtMinus120OrBelow() {
        #expect(LevelScale.isSilent(dbfs: -120.0))
        #expect(LevelScale.isSilent(dbfs: -130))
        #expect(!LevelScale.isSilent(dbfs: -119.9))
        #expect(!LevelScale.isSilent(dbfs: -70))
    }
}
