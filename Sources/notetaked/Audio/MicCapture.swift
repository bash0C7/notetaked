import AVFoundation

/// AVAudioEngine.inputNode に tap を付けてマイク入力を配信する。
/// `@unchecked Sendable`の根拠: `start`/`stop`は所有actor（CaptureStream）からのみ呼ばれ、
/// engineのtap callbackはAVAudioEngineが管理する単一のaudioスレッド上でしか実行されない。
final class MicCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()

    var format: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    init() {}

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            handler(buffer)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
