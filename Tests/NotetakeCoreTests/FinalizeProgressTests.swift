import Foundation
import Testing
@testable import NotetakeCore

@Test func progressLinesRoundTripAndRejectOtherLines() {
    let progress = FinalizeProgress(source: .system, stage: .diarize, percent: 42)
    #expect(progress.line == "finalize-progress system diarize 42")
    #expect(FinalizeProgress.parse(progress.line) == progress)
    #expect(progress.detail == "system 話者分離 42%")
    #expect(FinalizeProgress(source: .mic, stage: .transcribe, percent: 300).percent == 100)
    #expect(FinalizeProgress.parse("finalize-progress mic unknown 1") == nil)
    #expect(FinalizeProgress.parse("something else") == nil)
}

@Test func progressThrottleEmitsOnlyWhenThePercentRises() {
    var throttle = FinalizeProgressThrottle()
    #expect(throttle.percent(forFraction: 0) == 0)
    #expect(throttle.percent(forFraction: 0.004) == nil)
    #expect(throttle.percent(forFraction: 0.01) == 1)
    #expect(throttle.percent(forFraction: 0.5) == 50)
    #expect(throttle.percent(forFraction: 0.4) == nil)
    #expect(throttle.percent(forFraction: 1.2) == 100)
}
