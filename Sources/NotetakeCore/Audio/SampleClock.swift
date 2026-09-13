import AVFoundation

/// Transcriberの入力format（変換後）のサンプル数を壁時計ミリ秒へ換算する純粋計算。
/// Transcriberが`startMS`を作る式（origin + CMTime(sampleTime, timescale: sampleRate)）と同じ丸めにする。
/// 生マイクのサンプルレートは時刻に使わない（親spec「時刻基準」）
public struct SampleClock: Sendable {
    public let originMS: Int64
    public let sampleRate: Double

    public init(originMS: Int64, sampleRate: Double) {
        self.originMS = originMS
        self.sampleRate = sampleRate
    }

    public func ms(atFrame frame: AVAudioFramePosition) -> Int64 {
        originMS + Int64((Double(frame) / sampleRate * 1000).rounded())
    }
}
