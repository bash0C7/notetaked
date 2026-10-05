import Foundation

/// capture-daemonが書き、serveと確定処理が読む生音声（`<source>.pcm`）の形式。
/// 16kHz monoのFloat32 little endianをheader無しで並べるため、byte offsetを4で割るとsample番号になる
public enum CapturePCM {
    public static let sampleRate = 16_000
    public static let bytesPerSample = 4

    public static func ms(forSamples samples: Int64) -> Int64 {
        Int64((Double(samples) * 1000 / Double(sampleRate)).rounded())
    }

    public static func samples(forMS ms: Int64) -> Int64 {
        ms * Int64(sampleRate) / 1000
    }

    public static func encode(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * bytesPerSample)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                raw.storeBytes(
                    of: sample.bitPattern.littleEndian, toByteOffset: index * bytesPerSample, as: UInt32.self)
            }
        }
        return data
    }

    /// 4byteに満たない末尾の端数は無視する
    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / bytesPerSample
        return data.withUnsafeBytes { raw in
            (0..<count).map { index in
                Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(fromByteOffset: index * bytesPerSample, as: UInt32.self)))
            }
        }
    }
}
