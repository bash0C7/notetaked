import AudioToolbox
import AVFoundation
import CoreAudio
import NotetakeCore

/// AVAudioEngine.inputNode に tap を付けてマイク入力を配信する。既定の入力デバイスが変わると
/// engineは`AVAudioEngineConfigurationChangeNotification`を送って自身を停止するため、
/// それを購読してtapを新しいformatへ張り直しengineを再開する（issue #14）。
/// `pinnedUID`が指定されていれば、接続中である限り`AUHALPinnedCapture`（TN2091方式の生AUHAL
/// AudioUnit）でそのデバイスへ固定する。`AVAudioEngine.inputNode`に対する
/// `kAudioOutputUnitProperty_CurrentDevice`の直接設定はクラッシュ（`AudioUnitSetProperty`直後に
/// `outputFormat(forBus:)`を読むと`format.sampleRate == inputHWFormat.sampleRate`の検証に
/// 失敗する）や無音（`outputFormat(forBus:)`がハードウェアformatへ即座に追従しないため
/// `AudioConverter`が誤formatで構築され毎回黙って変換に失敗する）を引き起こすことが実機検証・
/// Web調査の両方で確認されており、pin時はAVAudioEngineを一切使わない。
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
    /// pin有りかつ接続中の間だけ非nil。非nilの間はAVAudioEngineを使わずこちらから配信する
    private var pinned: AUHALPinnedCapture?

    var format: AVAudioFormat {
        if let pinned { return pinned.format }
        return engine.inputNode.outputFormat(forBus: 0)
    }

    init(pinnedUID: String? = nil, onFallback: (@Sendable () -> Void)? = nil) {
        self.pinnedUID = pinnedUID
        self.onFallback = onFallback
        // `CaptureStream.init`は`start()`より前に`format`を読んでAudioConverterを組み立てるため、
        // pin適用をここで完了させる（`start()`まで遅らせると、`format`がpin前のOS既定デバイスの
        // ものになり、実際に届くbufferのformatと食い違ってconverterが毎回黙って失敗する）。
        // 以降pin解決をやり直さない（`format`が読まれた後にpin状態が変わると同じ食い違いが
        // 再発するため、initとstart/installTapで二重に解決していた従来の実装は行わない）
        applyPinnedDeviceIfNeeded()
    }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        if let pinned {
            try pinned.start(handler)
        } else {
            installTap()
            try engine.start()
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // pin中（`pinned`が非nil）はAVAudioEngineを一切使っていないためこの通知の対象外。
            // pin先の実際の切断は`wasDisconnectedNotification`（`handleDisconnect`）で別途検知する
            guard self.pinned == nil else { return }
            self.reinstallTap()
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
        if let pinned {
            pinned.stop()
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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

    /// pin中のデバイスが切断された時に呼ばれる。pin中でなければ、またはpin先と無関係な切断なら無視する。
    /// 生AUHALを停止し、AVAudioEngine（OS既定入力）へ切り替えてtapを張り直す
    private func handleDisconnect(uid: String) {
        guard let pinnedUID, uid == pinnedUID else { return }
        pinned?.stop()
        pinned = nil
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
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            handler(buffer)
        }
    }

    /// pinされたUIDが接続中デバイスに含まれていれば、TN2091方式の生AUHALをそのデバイスへ構築する。
    /// pin無し、pin先が接続中で無い、またはAudioUnit構築に失敗した場合は何もしない
    /// （`pinned`はnilのまま、OS既定入力＝AVAudioEngine経路を使う）。`init()`からのみ呼ばれる
    private func applyPinnedDeviceIfNeeded() {
        guard let pinnedUID else { return }
        let availableUIDs = Set(InputDeviceProbe.all().map(\.uid))
        guard
            InputDeviceResolution.resolvedUID(pinnedUID: pinnedUID, availableUIDs: availableUIDs) != nil,
            let audioDeviceID = InputDeviceProbe.audioDeviceID(forUID: pinnedUID)
        else { return }
        pinned = AUHALPinnedCapture(deviceID: audioDeviceID)
    }
}

/// Technical Note TN2091 "Device input using the HAL Output Audio Unit" の手順に従い、
/// AVAudioEngineを使わず生のAUHAL AudioUnitで指定デバイスから直接キャプチャする。
/// `MicCapture`がpin指定時にのみ使う。`AVAudioEngine.inputNode`へ`kAudioOutputUnitProperty_
/// CurrentDevice`を直接設定する方式はクラッシュ・無音を引き起こすため（`MicCapture`の型doc参照）、
/// こちらはengineを介さずCore Audioを直接叩く。`kAudioUnitProperty_StreamFormat`
/// （scope output, element 1）から取得した`format`が、そのデバイスの実際のネイティブformat
/// （`AVAudioEngine`の`outputFormat(forBus:)`とは異なり、`AudioUnitSetProperty`でデバイスを
/// 設定した直後でも正しい値を返す）。
/// `@unchecked Sendable`の根拠: `start`/`stop`は所有者（`MicCapture`、ひいてはCaptureStream
/// actor）からのみ呼ばれ、render callbackはCore Audioが管理するaudioスレッド上でしか実行されない。
/// `handler`は`start()`（callback登録・`AudioOutputUnitStart`より前）でのみ書き込まれ、callback
/// 実行中に書き換わることは無い
final class AUHALPinnedCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case setupFailed(step: String, status: OSStatus)
        case notConfigured
    }

    private var audioUnit: AudioUnit?
    /// このデバイスの実際のネイティブformat。`init`成功時に`kAudioUnitProperty_StreamFormat`から
    /// 取得済みで、以降変わらない
    let format: AVAudioFormat
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// 指定デバイスへの生AUHALを構築する。コンポーネント取得・IO有効化・デバイス設定・
    /// format取得のいずれかに失敗すればnil（呼び出し側はOS既定入力＝AVAudioEngine経路へ
    /// fallbackする）
    init?(deviceID: AudioDeviceID) {
        var descriptor = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &descriptor) else { return nil }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }

        // element 1 (input) のIOを有効化、element 0 (output) のIOを無効化する
        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        var mutableDeviceID = deviceID
        var streamDescription = AudioStreamBasicDescription()
        var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let configured =
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enableInput, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disableOutput, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            // TN2091: デバイスの実際のネイティブformatは常にelement 1のinput scopeに現れる
            // （output scope, element 1はクライアントが「受け取りたいformat」を明示的に
            // setするためのものであり、何もsetしていない状態でgetしても未定義に近い値しか
            // 返らない）
            && AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                &streamDescription, &descriptionSize) == noErr
            // 上で取得したネイティブformatをそのままoutput scope, element 1へsetする。
            // これによりAudioUnitRenderが返すbufferはネイティブformatのままになり
            // （AUHAL内部での変換を挟まない）、`format`プロパティと実際に届くbufferの
            // formatが一致することが保証される
            && AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &streamDescription, descriptionSize) == noErr

        guard configured, let resolvedFormat = AVAudioFormat(streamDescription: &streamDescription)
        else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        self.audioUnit = unit
        self.format = resolvedFormat
    }

    /// render callbackを登録し`AudioUnitInitialize` → `AudioOutputUnitStart`する。
    /// callbackはstart後のaudioスレッドから届くため、登録前に`handler`を設定しておく
    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let audioUnit else { throw CaptureError.notConfigured }
        self.handler = handler

        var callback = AURenderCallbackStruct(
            inputProc: auhalPinnedCaptureRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let callbackStatus = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard callbackStatus == noErr else {
            throw CaptureError.setupFailed(step: "SetInputCallback", status: callbackStatus)
        }

        let initStatus = AudioUnitInitialize(audioUnit)
        guard initStatus == noErr else {
            throw CaptureError.setupFailed(step: "AudioUnitInitialize", status: initStatus)
        }

        let startStatus = AudioOutputUnitStart(audioUnit)
        guard startStatus == noErr else {
            throw CaptureError.setupFailed(step: "AudioOutputUnitStart", status: startStatus)
        }
    }

    /// `AudioOutputUnitStop` → `AudioUnitUninitialize` → `AudioComponentInstanceDispose`の順で
    /// 停止・破棄する（TN2091の手順）
    func stop() {
        guard let audioUnit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        handler = nil
    }

    /// render callback本体。`AudioUnitRender`で取得したbufferを、`init`時に取得済みの
    /// ネイティブformatで`AVAudioPCMBuffer`として`handler`へ渡す
    fileprivate func render(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let audioUnit, let handler else { return noErr }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames)
        else { return noErr }
        pcmBuffer.frameLength = inNumberFrames

        let status = AudioUnitRender(
            audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
            pcmBuffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        handler(pcmBuffer)
        return noErr
    }
}

/// `AUHALPinnedCapture.start`が`kAudioOutputUnitProperty_SetInputCallback`へ登録するCのrender
/// callback。`AURenderCallback`は`@convention(c)`でSwiftのクロージャキャプチャを使えないため、
/// `inRefCon`（`start()`で渡した`Unmanaged.passUnretained(self)`）経由でインスタンスを復元する
private func auhalPinnedCaptureRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AUHALPinnedCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(
        ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames)
}
