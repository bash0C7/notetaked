import AVFoundation

/// AVAudioEngine.inputNode に tap を付けてマイク入力を配信する。既定の入力デバイスが変わると
/// engineは`AVAudioEngineConfigurationChangeNotification`を送って自身を停止するため、
/// それを購読してtapを新しいformatへ張り直しengineを再開する（issue #14）。
/// `@unchecked Sendable`の根拠: `start`/`stop`は所有actor（CaptureStream）からのみ呼ばれ、
/// engineのtap callbackとconfiguration change通知はAVAudioEngineが管理するスレッド上でしか実行されない。
final class MicCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var configObserver: NSObjectProtocol?

    var format: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    init() {}

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        installTap()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.reinstallTap()
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    /// 既定入力デバイスが変わった時（AirPods接続/切断等）に呼ばれる。engineは通知の時点で
    /// 既に内部停止しているため、新しいinputNodeのformatでtapを張り直してから再開する
    private func reinstallTap() {
        guard handler != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        engine.prepare()
        try? engine.start()
    }

    private func installTap() {
        guard let handler else { return }
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            handler(buffer)
        }
    }
}
