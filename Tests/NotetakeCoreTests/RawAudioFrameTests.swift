import Foundation
import Testing
@testable import NotetakeCore

@Test func encodeDecodeRoundTrip() {
    let frame = RawAudioFrame(sampleRate: 48000, channelCount: 1, samples: [0.1, -0.2, 0.3, 0.0])
    let data = frame.encoded()
    let decoded = RawAudioFrame.decode(from: data, at: 0)
    #expect(decoded != nil)
    #expect(decoded?.frame == frame)
    #expect(decoded?.nextOffset == data.count)
}

@Test func decodeReturnsNilOnPartialFrame() {
    let frame = RawAudioFrame(sampleRate: 16000, channelCount: 2, samples: [1, 2, 3, 4])
    let full = frame.encoded()
    let partial = full.prefix(full.count - 1)
    #expect(RawAudioFrame.decode(from: Data(partial), at: 0) == nil)
}

@Test func decodeReturnsNilWhenLessThanHeaderSize() {
    #expect(RawAudioFrame.decode(from: Data([0, 1, 2]), at: 0) == nil)
}

@Test func multipleFramesConcatenateAndDecodeSequentially() {
    let a = RawAudioFrame(sampleRate: 48000, channelCount: 1, samples: [1, 2])
    let b = RawAudioFrame(sampleRate: 48000, channelCount: 1, samples: [3, 4, 5])
    var combined = a.encoded()
    combined.append(b.encoded())
    let (firstFrame, offsetAfterFirst) = RawAudioFrame.decode(from: combined, at: 0)!
    #expect(firstFrame == a)
    let (secondFrame, offsetAfterSecond) = RawAudioFrame.decode(from: combined, at: offsetAfterFirst)!
    #expect(secondFrame == b)
    #expect(offsetAfterSecond == combined.count)
}
