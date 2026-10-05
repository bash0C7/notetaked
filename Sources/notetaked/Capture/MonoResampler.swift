import AVFoundation
import Foundation
import NotetakeCore

enum MonoResamplerError: Error {
    case unsupportedSampleRate(Double)
    case bufferUnavailable
    case conversionFailed
}

/// 音声のcallbackで受け取ったbufferの写し。変換と書き込みをcallbackの外で行うため、記録用のqueueへ渡す
struct CapturedChunk: Sendable {
    let sampleRate: Double
    let channelCount: Int
    /// trueならframeごとにchannelが並び、falseならchannelごとのsample列を順に連結している
    let interleaved: Bool
    let samples: [Float]
    let receivedAt: Date

    var frameCount: Int { samples.count / channelCount }

    init(sampleRate: Double, channelCount: Int, interleaved: Bool, samples: [Float], receivedAt: Date) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.interleaved = interleaved
        self.samples = samples
        self.receivedAt = receivedAt
    }

    /// Float32でないformatと空のbufferはnil
    init?(buffer: AVAudioPCMBuffer, receivedAt: Date) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return nil }
        let interleaved = buffer.format.isInterleaved
        var copied: [Float] = []
        copied.reserveCapacity(frames * channels)
        if interleaved {
            copied.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames * channels))
        } else {
            for channel in 0..<channels {
                copied.append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames))
            }
        }
        self.init(
            sampleRate: buffer.format.sampleRate, channelCount: channels, interleaved: interleaved,
            samples: copied, receivedAt: receivedAt)
    }

    /// channelの平均をとってmonoにする
    func mono() -> [Float] {
        guard channelCount > 1 else { return samples }
        let frames = frameCount
        let scale = 1 / Float(channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved ? samples[frame * channelCount + channel] : samples[channel * frames + frame]
            }
            mono[frame] = sum * scale
        }
        return mono
    }
}

/// 入力機器のsample rateのmono音声を、生音声の16kHzへ変換する。
/// AVAudioConverterの状態をbufferをまたいで保つため、bufferの境目で音が欠けたりsample数がずれたりしない。
/// sample rateが変わった時だけ、それまでの残りを出し切ってから変換器を作り直す
final class MonoResampler {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    /// 今の変換器へ渡した音声の長さ（16kHzのsample数）
    private var consumed: Double = 0
    /// 今の変換器が出したsampleの数
    private var produced = 0

    /// 受け取った音声のうち、変換器がまだ出していないsampleの数。変換器は先のsampleを使って
    /// 計算するため、出力はbuffer1つ分ほど遅れて出てくる。次のbufferの先頭は、出力済みの数にこれを足した位置に入る
    var pendingSamples: Int { Int(consumed.rounded()) - produced }

    init() {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(CapturePCM.sampleRate), channels: 1,
                interleaved: false)
        else {
            preconditionFailure("16kHz mono Float32 is always a valid format")
        }
        outputFormat = format
    }

    func convert(_ chunk: CapturedChunk) throws -> [Float] {
        var output: [Float] = []
        if let converter, converter.inputFormat.sampleRate != chunk.sampleRate {
            output += try finish(converter)
        }
        let mono = chunk.mono()
        if chunk.sampleRate == outputFormat.sampleRate {
            return output + mono
        }
        let converter = try self.converter ?? makeConverter(sampleRate: chunk.sampleRate)
        self.converter = converter
        let converted = try drain(
            converter, input: try makeBuffer(mono, format: converter.inputFormat), endOfStream: false)
        consumed += Double(mono.count) * outputFormat.sampleRate / chunk.sampleRate
        produced += converted.count
        return output + converted
    }

    /// 変換器に残っているsampleを出し切る。書き込み先を切り替える時と止める時に呼ぶ
    func flush() throws -> [Float] {
        guard let converter else { return [] }
        return try finish(converter)
    }

    private func finish(_ converter: AVAudioConverter) throws -> [Float] {
        self.converter = nil
        consumed = 0
        produced = 0
        return try drain(converter, input: nil, endOfStream: true)
    }

    private func makeConverter(sampleRate: Double) throws -> AVAudioConverter {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw MonoResamplerError.unsupportedSampleRate(sampleRate)
        }
        return converter
    }

    private func makeBuffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw MonoResamplerError.bufferUnavailable
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// `input`を1度だけ渡し、変換器が出せる分を出し切るまでconvertを繰り返す
    private func drain(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> [Float] {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input?.frameLength ?? 0) * ratio).rounded(.up)) + 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw MonoResamplerError.bufferUnavailable
        }
        var collected: [Float] = []
        // convertは渡したblockを同じ呼び出しの中で同期的に呼ぶため、`supplied`を並行に触ることはない
        nonisolated(unsafe) var supplied = false
        while true {
            buffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let conversionError {
                throw conversionError
            }
            if buffer.frameLength > 0, let data = buffer.floatChannelData {
                collected.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            switch status {
            case .haveData:
                if buffer.frameLength == 0 { return collected }
            case .inputRanDry, .endOfStream:
                return collected
            case .error:
                throw MonoResamplerError.conversionFailed
            @unknown default:
                return collected
            }
        }
    }
}
