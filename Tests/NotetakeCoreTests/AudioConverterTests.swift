import Foundation
import Testing
import AVFoundation
@testable import NotetakeCore

@Test func convertsRateAndChannels() throws {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let frameCount: AVAudioFrameCount = 4800
    let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    let frequency = 440.0
    let sampleRate = 48_000.0
    for channel in 0..<2 {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frameCount) {
            data[i] = Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let converter = try AudioConverter(from: inputFormat, to: outputFormat)
    let converted = try converter.convert(buffer)

    #expect(abs(Int(converted.frameLength) - 1600) <= 2)
    let dbfs = AudioLevel.dbfs(converted)
    #expect(dbfs > -4 && dbfs < -2)
}
