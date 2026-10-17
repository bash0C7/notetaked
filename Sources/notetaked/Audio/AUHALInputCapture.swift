import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

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
