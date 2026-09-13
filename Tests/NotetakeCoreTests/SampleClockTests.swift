import AVFoundation
import Testing
@testable import NotetakeCore

@Test func sampleClockConvertsFramesAtInputRate() {
    let clock = SampleClock(originMS: 1_000_000, sampleRate: 16000)
    #expect(clock.ms(atFrame: 0) == 1_000_000)
    #expect(clock.ms(atFrame: 16000) == 1_001_000)
    #expect(clock.ms(atFrame: 8000) == 1_000_500)
}

@Test func sampleClockRoundsLikeTranscriber() {
    // Transcriber.makePiece: originMS + round(CMTimeGetSeconds(CMTime(value: frame, timescale: rate)) * 1000)
    let clock = SampleClock(originMS: 0, sampleRate: 16000)
    for frame: AVAudioFramePosition in [1, 7, 8, 9, 15, 16, 12345, 987_654] {
        let expected = Int64((CMTimeGetSeconds(CMTime(value: frame, timescale: 16000)) * 1000).rounded())
        #expect(clock.ms(atFrame: frame) == expected)
    }
}
