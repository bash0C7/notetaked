import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import NotetakeCore
import os

/// 既定の入力機器か、固定した入力機器から、AUHALで音声を取り込む。
/// AVAudioEngineは入力と出力を1組のI/Oとして扱うため、出力機器（AirPodsなど）と入力機器が違うと、
/// startが`-10868`で失敗したり、startが成功しても音声が1つも届かなかったりする。AUHALは入力だけを開くので影響を受けない。
/// 既定の入力・機器の一覧・今の機器のサンプルレートが変わった時、取り込みを始められなかった時、
/// 音声が`CaptureStall.timeout`届かない時に、取り込みを作り直す。
/// 失敗は1秒から倍にしていき最大30秒間隔で再試行する。固定した機器が使えない時は既定の入力へ戻し、`noteInput`で伝える
actor MicCapture: SourceCapture {
    private let pinnedUID: String?
    private var sink: (any CaptureSink)?
    private var capture: AUHALInputCapture?
    private var captureDeviceID: AudioDeviceID?
    private var captureStartedAt = Date()
    /// 固定した機器を開けなかった。機器の一覧が変わるまで、既定の入力を使う
    private var pinnedUnusable = false
    private var observers: [AudioObjectObserver] = []
    private var rateObserver: AudioObjectObserver?
    private var retryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var failures = 0

    init(pinnedUID: String?) {
        self.pinnedUID = pinnedUID
    }

    func start(into sink: any CaptureSink) async {
        self.sink = sink
        observeHardware()
        rebuild()
        startWatchdog()
    }

    func stop() async {
        sink = nil
        retryTask?.cancel()
        retryTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        observers = []
        rateObserver = nil
        capture?.stop()
        capture = nil
        captureDeviceID = nil
    }

    /// 取り込む機器。固定した機器が接続中ならそれ、無ければ既定の入力。どちらも無ければnil
    private func target() -> (id: AudioDeviceID, fellBackFromPinned: Bool)? {
        if !pinnedUnusable,
            let uid = InputDeviceResolution.resolvedUID(
                pinnedUID: pinnedUID, availableUIDs: Set(InputDeviceProbe.all().map(\.uid))),
            let id = InputDeviceProbe.audioDeviceID(forUID: uid)
        {
            return (id, false)
        }
        guard let id = InputDeviceProbe.defaultInputDeviceID() else { return nil }
        return (id, pinnedUID != nil)
    }

    private func rebuild() {
        guard let sink else { return }
        retryTask?.cancel()
        retryTask = nil
        rateObserver = nil
        capture?.stop()
        capture = nil
        captureDeviceID = nil
        guard let target = target() else {
            fail("入力機器がありません")
            return
        }
        guard let next = AUHALInputCapture(deviceID: target.id) else {
            openFailed(target: target, detail: "設定できません")
            return
        }
        do {
            try next.start(into: sink)
        } catch {
            next.stop()
            openFailed(target: target, detail: "\(error)")
            return
        }
        capture = next
        captureDeviceID = target.id
        captureStartedAt = Date()
        failures = 0
        observeSampleRate(of: target.id)
        sink.noteInput(InputDeviceProbe.inputDevice(forID: target.id), fellBackFromPinned: target.fellBackFromPinned)
        sink.noteState(.recording, reason: nil)
    }

    /// 固定した機器を開けなかった時は、固定を残したまま既定の入力で取り込み、そのことを伝える
    private func openFailed(target: (id: AudioDeviceID, fellBackFromPinned: Bool), detail: String) {
        if pinnedUID != nil, !pinnedUnusable, !target.fellBackFromPinned {
            pinnedUnusable = true
            sink?.noteError("固定した入力機器を開けないため、既定の入力で取り込みます: \(detail)")
            rebuild()
            return
        }
        fail("入力機器を開けません: \(detail)")
    }

    private func fail(_ reason: String) {
        sink?.noteState(.retrying, reason: reason)
        let delay = Duration.seconds(RetryBackoff.seconds(afterFailures: failures))
        failures += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    /// 既定の入力か機器の一覧が変わった。取り込み中の機器が今の取り込み先と違えば作り直す
    private func hardwareChanged(devicesChanged: Bool) {
        guard sink != nil else { return }
        if devicesChanged { pinnedUnusable = false }
        if capture == nil || target()?.id != captureDeviceID {
            rebuild()
        }
    }

    private func observeHardware() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (selector, devices) in [(kAudioHardwarePropertyDefaultInputDevice, false), (kAudioHardwarePropertyDevices, true)] {
            observers.append(
                AudioObjectObserver(object: system, selector: selector) { [weak self] in
                    Task { await self?.hardwareChanged(devicesChanged: devices) }
                })
        }
    }

    /// AirPodsは入力を開くと通話用のprofileへ切り替わりサンプルレートが変わる。レートが変わったら作り直す
    private func observeSampleRate(of deviceID: AudioDeviceID) {
        rateObserver = AudioObjectObserver(object: deviceID, selector: kAudioDevicePropertyNominalSampleRate) {
            [weak self] in
            Task { await self?.sampleRateChanged(deviceID: deviceID) }
        }
    }

    private func sampleRateChanged(deviceID: AudioDeviceID) {
        guard sink != nil, captureDeviceID == deviceID else { return }
        rebuild()
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.checkStall()
            }
        }
    }

    private func checkStall() {
        guard let capture, let sink else { return }
        guard CaptureStall.isStalled(lastBufferAt: capture.lastBufferAt, startedAt: captureStartedAt, now: Date())
        else { return }
        sink.noteState(.retrying, reason: "音声が\(Int(CaptureStall.timeout))秒届かないため、取り込みを作り直します")
        rebuild()
    }
}

/// CoreAudioのオブジェクトのpropertyの変化を受ける。解放されると登録を外す
final class AudioObjectObserver: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue = DispatchQueue(label: "AudioObjectObserver")
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

/// Technical Note TN2091の手順で、AVAudioEngineを使わずAUHALで指定した機器から取り込む。
/// formatは機器の入力側（input scope, element 1）から読み、同じformatを出力側へ設定するため、
/// 届くbufferのformatは常に`format`と一致する。
/// `@unchecked Sendable`: `start`と`stop`は所有する`MicCapture`（actor）からだけ呼ばれ、
/// render callbackはCore Audioのaudioのthreadで`sink`を読むだけである
final class AUHALInputCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case setupFailed(step: String, status: OSStatus)
        case notConfigured
    }

    private var audioUnit: AudioUnit?
    let format: AVAudioFormat
    private var sink: (any CaptureSink)?
    /// 直前のrender callbackの結果。audioのthreadだけが読み書きし、失敗が変わった時だけ伝える
    private var lastRenderFailure: OSStatus = noErr
    private let lastBuffer = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// 直前にbufferが届いた時刻。まだ届いていなければnil
    var lastBufferAt: Date? { lastBuffer.withLock { $0 } }

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
            inputProc: auhalInputCaptureRenderCallback,
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
        lastBuffer.withLock { $0 = Date() }
        sink.ingest(pcmBuffer)
        return noErr
    }

    private func noteRenderFailure(_ status: OSStatus, to sink: any CaptureSink, what: String) {
        guard status != lastRenderFailure else { return }
        lastRenderFailure = status
        sink.noteError("入力機器の音声を取り込めません（\(what): \(status)）")
    }
}

/// `AURenderCallback`は`@convention(c)`でclosureの捕捉を使えないため、`inRefCon`からインスタンスを戻す
private func auhalInputCaptureRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AUHALInputCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(
        ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames)
}
