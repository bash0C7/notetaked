@preconcurrency import AVFoundation

public enum AudioConverterError: Error {
    case creationFailed
    case bufferAllocationFailed
    case conversionFailed
}

/// AVAudioConverterのwrapper。入力formatから出力formatへ、frame数を出力側rateに換算して変換する
public final class AudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    public init(from: AVAudioFormat, to: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: from, to: to) else {
            throw AudioConverterError.creationFailed
        }
        self.converter = converter
        self.outputFormat = to
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> sending AVAudioPCMBuffer {
        // Each call is a complete, self-contained conversion (we signal
        // .endOfStream once the buffer is consumed). Reset any leftover
        // state from a previous call so repeated calls on the same
        // instance keep producing output instead of being treated as
        // input after the stream already ended.
        converter.reset()

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity =
            AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outputFrameCapacity)
        else {
            throw AudioConverterError.bufferAllocationFailed
        }

        var conversionError: NSError?
        // AVAudioConverter invokes this block synchronously and repeatedly
        // within the `convert(to:error:withInputFrom:)` call below, on
        // whatever thread that call executes on. It never escapes past
        // that single call, so the block's own execution is never
        // concurrent with itself; `nonisolated(unsafe)` documents that the
        // compiler's generic "concurrently-executing code" warning does
        // not apply to this specific, single-threaded, synchronous usage.
        nonisolated(unsafe) var provided = false
        let inputBuffer = buffer
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, inputStatus in
            if provided {
                inputStatus.pointee = .endOfStream
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw AudioConverterError.conversionFailed
        }
        return outputBuffer
    }
}
