import AVFoundation
import Testing
@testable import NotetakeCore

@Test func pcmBufferCopiesTheSamplesIntoAMonoFloatBuffer() throws {
    let buffer = try PCMBuffer.make(samples: [0.5, -0.25, 1], format: PCMBuffer.captureFormat())
    #expect(buffer.frameLength == 3)
    #expect(buffer.format.sampleRate == 16_000)
    #expect(buffer.format.channelCount == 1)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect([channel[0], channel[1], channel[2]] == [0.5, -0.25, 1])
}

@Test func pcmBufferCannotHoldNoSamples() {
    #expect(throws: AudioConverterError.bufferAllocationFailed) {
        _ = try PCMBuffer.make(samples: [], format: PCMBuffer.captureFormat())
    }
}
