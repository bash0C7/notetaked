import AudioToolbox
import AVFoundation
import NotetakeCore

/// AVAudioEngine.inputNode に tap を付けてマイク入力を配信する。既定の入力デバイスが変わると
/// engineは`AVAudioEngineConfigurationChangeNotification`を送って自身を停止するため、
/// それを購読してtapを新しいformatへ張り直しengineを再開する（issue #14）。
/// `pinnedUID`が指定されていれば、接続中である限りCoreAudio経由でそのデバイスへ固定する
/// （macOSでは`AVAudioEngine.inputNode`はOS既定デバイスにしか繋がらないため）。
/// pinしたデバイスが切断された場合は`AVCaptureDevice.wasDisconnectedNotification`で検知し、
/// 録音を止めずに即座にOS既定へフォールバックしてtapを張り直す（入力デバイス明示選択機能）。
/// `@unchecked Sendable`の根拠: `start`/`stop`は所有actor（CaptureStream）からのみ呼ばれ、
/// engineのtap callbackとconfiguration change / disconnect通知はAVAudioEngineとAVFoundationが
/// 管理するスレッド上でしか実行されない。
final class MicCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    /// 固定したい入力デバイスのUID。nilなら常にOS既定を使う（#14の既存動作のまま）
    private let pinnedUID: String?
    /// pin先デバイスが切断されOS既定へフォールバックした時に呼ばれる
    private let onFallback: (@Sendable () -> Void)?

    var format: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    init(pinnedUID: String? = nil, onFallback: (@Sendable () -> Void)? = nil) {
        self.pinnedUID = pinnedUID
        self.onFallback = onFallback
    }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        installTap()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.reinstallTap()
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.handleDisconnect(uid: device.uniqueID)
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        disconnectObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    /// pin状態を踏まえた現在の入力機材。pinが有効かつ接続中ならその機材、それ以外は
    /// `InputDeviceProbe.current()`（OS既定）。毎回`InputDeviceProbe.all()`から再計算するため、
    /// 別スレッド（stream eventのconsumer task）から呼んでも共有可変状態を持たない
    func currentInputDevice() -> InputDevice {
        guard let pinnedUID else { return InputDeviceProbe.current() }
        let available = InputDeviceProbe.all()
        guard
            InputDeviceResolution.resolvedUID(pinnedUID: pinnedUID, availableUIDs: Set(available.map(\.uid)))
                != nil,
            let device = available.first(where: { $0.uid == pinnedUID })
        else { return InputDeviceProbe.current() }
        return device
    }

    /// pin中のデバイスが切断された時に呼ばれる。pin中でなければ、またはpin先と無関係な切断なら無視する
    private func handleDisconnect(uid: String) {
        guard let pinnedUID, uid == pinnedUID else { return }
        reinstallTap()
        onFallback?()
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
        applyPinnedDeviceIfNeeded()
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            handler(buffer)
        }
    }

    /// pinされたUIDが接続中デバイスに含まれていれば、CoreAudio経由でengineのinputNodeへ固定する。
    /// pin無し、またはpin先が接続中で無ければ何もしない（OS既定入力のまま）
    private func applyPinnedDeviceIfNeeded() {
        guard let pinnedUID else { return }
        let availableUIDs = Set(InputDeviceProbe.all().map(\.uid))
        guard
            InputDeviceResolution.resolvedUID(pinnedUID: pinnedUID, availableUIDs: availableUIDs) != nil,
            var audioDeviceID = InputDeviceProbe.audioDeviceID(forUID: pinnedUID),
            let audioUnit = engine.inputNode.audioUnit
        else { return }
        AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &audioDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}
