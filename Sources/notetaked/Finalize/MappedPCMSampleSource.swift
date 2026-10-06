import FluidAudio
import Foundation
import NotetakeCore

/// 生音声（16kHz monoのFloat32 little endian、header無し）をmemory mapし、FluidAudioへそのまま渡す。
/// 4byteに満たない末尾の端数は読まない。arm64とx86_64はどちらもlittle endianなので、byte列をそのままFloatとして読める
struct MappedPCMSampleSource: AudioSampleSource {
    private let data: Data
    let sampleCount: Int

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        sampleCount = data.count / CapturePCM.bytesPerSample
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0, offset >= 0, offset < sampleCount else { return }
        let available = min(sampleCount - offset, count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(destination, base.advanced(by: offset * CapturePCM.bytesPerSample), available * CapturePCM.bytesPerSample)
        }
    }

    /// `range`のsample。ファイルの終わりを超える分は返さない
    func samples(in range: Range<Int64>) -> [Float] {
        let lower = max(0, Int(range.lowerBound))
        let upper = min(sampleCount, Int(range.upperBound))
        guard lower < upper else { return [] }
        var result = [Float](repeating: 0, count: upper - lower)
        result.withUnsafeMutableBufferPointer { buffer in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, let destination = buffer.baseAddress else { return }
                memcpy(
                    destination, base.advanced(by: lower * CapturePCM.bytesPerSample),
                    (upper - lower) * CapturePCM.bytesPerSample)
            }
        }
        return result
    }
}
