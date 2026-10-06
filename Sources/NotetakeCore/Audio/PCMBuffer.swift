@preconcurrency import AVFoundation

public enum PCMBuffer {
    /// 16kHz mono Float32（非interleaved）のsampleを、`AVAudioPCMBuffer`へ写す。sampleが空なら
    /// `bufferAllocationFailed`（長さ0のbufferは作れない）
    public static func make(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw AudioConverterError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// 生音声（16kHz mono Float32）の形式
    public static func captureFormat() -> AVAudioFormat {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(CapturePCM.sampleRate), channels: 1,
                interleaved: false)
        else {
            preconditionFailure("16kHz mono Float32 is always a valid format")
        }
        return format
    }
}
