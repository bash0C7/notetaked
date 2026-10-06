import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import NotetakeCore

/// 既定の入力機器（AVAudioEngine）か、固定した入力機器（AUHAL）から音声を取り込む。
/// AVAudioEngineは既定の入力が変わると自ら止まるため、構成変更の通知でtapを張り直す。
/// `engine.start()`が失敗したら、1秒から倍にしていき最大30秒間隔で再試行する。
/// 固定した機器が外れたら既定の入力へ戻し、そのことを`noteInput`で伝える
actor MicCapture: SourceCapture {
    private let pinnedUID: String?
    private let engine = AVAudioEngine()
    private var sink: (any CaptureSink)?
    private var pinned: AUHALPinnedCapture?
    private var fellBack = false
    private var observers: [any NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var failures = 0

    init(pinnedUID: String?) {
        self.pinnedUID = pinnedUID
    }

    func start(into sink: any CaptureSink) async {
        self.sink = sink
        observeDevices()
        if startPinnedIfAvailable(sink) { return }
        startEngine()
    }

    func stop() async {
        sink = nil
        retryTask?.cancel()
        retryTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        pinned?.stop()
        pinned = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// 固定した機器が接続中ならAUHALで取り込む。AVAudioEngineの入力に機器を直接設定すると、
    /// formatが追従せずcrashや無音になるため、固定時はAVAudioEngineを使わない。
    /// 接続中なのに開けなかった時は、固定を残したまま既定の入力で取り込み、そのことを伝える
    private func startPinnedIfAvailable(_ sink: any CaptureSink) -> Bool {
        guard
            let pinnedUID,
            let device = InputDeviceProbe.all().first(where: { $0.uid == pinnedUID }),
            let deviceID = InputDeviceProbe.audioDeviceID(forUID: pinnedUID)
        else { return false }
        guard let capture = AUHALPinnedCapture(deviceID: deviceID) else {
            fallBackToDefaultInput(sink, detail: "設定できません")
            return false
        }
        do {
            try capture.start(into: sink)
        } catch {
            capture.stop()
            fallBackToDefaultInput(sink, detail: "\(error)")
            return false
        }
        pinned = capture
        sink.noteInput(device, fellBackFromPinned: false)
        sink.noteState(.recording, reason: nil)
        return true
    }

    private func fallBackToDefaultInput(_ sink: any CaptureSink, detail: String) {
        fellBack = true
        sink.noteError("固定した入力機器を開けないため、既定の入力で取り込みます: \(detail)")
    }

    private func startEngine() {
        guard let sink else { return }
        retryTask?.cancel()
        retryTask = nil
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("入力機器がありません")
            return
        }
        // AVAudioNodeTapBlockは@Sendableではないため、明示しないとactorに隔離されたclosureと推論され、
        // audioのthreadから呼ばれた時に実行時の隔離検査で止まる
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            sink.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail(error.localizedDescription)
            return
        }
        failures = 0
        sink.noteInput(InputDeviceProbe.current(), fellBackFromPinned: fellBack)
        sink.noteState(.recording, reason: nil)
    }

    private func fail(_ reason: String) {
        sink?.noteState(.retrying, reason: reason)
        let delay = Duration.seconds(RetryBackoff.seconds(afterFailures: failures))
        failures += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.restartEngine()
        }
    }

    private func restartEngine() {
        guard sink != nil, pinned == nil else { return }
        startEngine()
    }

    private func observeDevices() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
                [weak self] _ in
                Task { await self?.restartEngine() }
            })
        observers.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
                [weak self] notification in
                guard let uid = (notification.object as? AVCaptureDevice)?.uniqueID else { return }
                Task { await self?.deviceDisconnected(uid: uid) }
            })
    }

    private func deviceDisconnected(uid: String) {
        guard uid == pinnedUID, let pinned, let sink else { return }
        pinned.stop()
        self.pinned = nil
        fellBack = true
        sink.noteState(.retrying, reason: "固定した入力機器が外れたため、既定の入力へ切り替えます")
        startEngine()
    }
}

/// Technical Note TN2091の手順で、AVAudioEngineを使わずAUHALで指定した機器から取り込む。
/// formatは機器の入力側（input scope, element 1）から読み、同じformatを出力側へ設定するため、
/// 届くbufferのformatは常に`format`と一致する。
/// `@unchecked Sendable`: `start`と`stop`は所有する`MicCapture`（actor）からだけ呼ばれ、
/// render callbackはCore Audioのaudioのthreadで`sink`を読むだけである
final class AUHALPinnedCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case setupFailed(step: String, status: OSStatus)
        case notConfigured
    }

    private var audioUnit: AudioUnit?
    let format: AVAudioFormat
    private var sink: (any CaptureSink)?
    /// 直前のrender callbackの結果。audioのthreadだけが読み書きし、失敗が変わった時だけ伝える
    private var lastRenderFailure: OSStatus = noErr

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
            && AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                &streamDescription, &descriptionSize) == noErr
            && AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &streamDescription, descriptionSize) == noErr

        guard configured, let resolvedFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        audioUnit = unit
        format = resolvedFormat
    }

    /// render callbackを登録してから開始する。callbackは開始後にaudioのthreadから届くため、先に`sink`を設定する
    func start(into sink: any CaptureSink) throws {
        guard let audioUnit else { throw CaptureError.notConfigured }
        self.sink = sink

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

    func stop() {
        guard let audioUnit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        sink = nil
    }

    fileprivate func render(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let audioUnit, let sink else { return noErr }
        guard inNumberFrames > 0 else { return noErr }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames) else {
            noteRenderFailure(kAudio_MemFullError, to: sink, what: "bufferを確保できません")
            return noErr
        }
        pcmBuffer.frameLength = inNumberFrames
        let status = AudioUnitRender(
            audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
            pcmBuffer.mutableAudioBufferList)
        guard status == noErr else {
            noteRenderFailure(status, to: sink, what: "AudioUnitRenderが失敗しました")
            return status
        }
        lastRenderFailure = noErr
        sink.ingest(pcmBuffer)
        return noErr
    }

    private func noteRenderFailure(_ status: OSStatus, to sink: any CaptureSink, what: String) {
        guard status != lastRenderFailure else { return }
        lastRenderFailure = status
        sink.noteError("固定した入力機器の音声を取り込めません（\(what): \(status)）")
    }
}

/// `AURenderCallback`は`@convention(c)`でclosureの捕捉を使えないため、`inRefCon`からインスタンスを戻す
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
