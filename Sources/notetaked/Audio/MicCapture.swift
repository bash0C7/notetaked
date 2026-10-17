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

    /// 取り込む機器。固定した機器が接続中ならそれ、無ければ既定の入力（Continuityならば内蔵）。使える機器が無ければnil
    private func target() -> (id: AudioDeviceID, fellBackFromPinned: Bool)? {
        InputDeviceProbe.captureTarget(pinnedUID: pinnedUID, pinnedUnusable: pinnedUnusable)
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
            fail("使える入力機器がありません（iPhoneのマイクは自動では使いません）")
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
