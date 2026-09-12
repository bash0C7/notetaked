import AVFoundation
import CoreAudio
import Foundation

enum SystemAudioCaptureError: Error {
    case osStatus(String, OSStatus)
}

/// CoreAudio process tapで自process以外の全システム音声をcaptureする
final class SystemAudioCapture: AudioCapture, @unchecked Sendable {
    // @unchecked Sendable: tapID/aggregateDeviceID/ioProcIDはCoreAudioが管理するopaque handleで、
    // start/stopはMicCaptureのAVAudioEngineラップと同様にシリアルに呼ばれる想定
    private var tapID: AudioObjectID
    private var aggregateDeviceID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private var stopped = false

    let format: AVAudioFormat

    init() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            throw SystemAudioCaptureError.osStatus("AudioHardwareCreateProcessTap", tapStatus)
        }
        self.tapID = tapID

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "notetaked-system-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString]
            ],
        ]

        var aggregateDeviceID: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregateDeviceID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemAudioCaptureError.osStatus(
                "AudioHardwareCreateAggregateDevice", aggregateStatus)
        }
        self.aggregateDeviceID = aggregateDeviceID

        var asbd = AudioStreamBasicDescription()
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(
            tapID, &propertyAddress, 0, nil, &dataSize, &asbd)
        guard formatStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemAudioCaptureError.osStatus(
                "AudioObjectGetPropertyData(kAudioTapPropertyFormat)", formatStatus)
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemAudioCaptureError.osStatus(
                "AVAudioFormat(streamDescription:)", kAudio_ParamError)
        }
        self.format = format
    }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let format = self.format
        var newIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID, aggregateDeviceID, nil
        ) { _, inInputData, _, _, _ in
            guard let buffer = Self.makeBuffer(from: inInputData, format: format) else { return }
            handler(buffer)
        }
        guard createStatus == noErr, let newIOProcID else {
            throw SystemAudioCaptureError.osStatus(
                "AudioDeviceCreateIOProcIDWithBlock", createStatus)
        }
        ioProcID = newIOProcID

        let startStatus = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, newIOProcID)
            ioProcID = nil
            throw SystemAudioCaptureError.osStatus("AudioDeviceStart", startStatus)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit {
        stop()
    }

    /// IOProcのinInputDataをAVAudioPCMBufferへコピーする。real-timeスレッドで呼ばれるためallocationはbuffer確保のみ
    private static func makeBuffer(
        from inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = inputList.first, firstBuffer.mDataByteSize > 0 else { return nil }

        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = firstBuffer.mDataByteSize / bytesPerFrame
        guard frameCount > 0,
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        pcmBuffer.frameLength = frameCount

        let outputList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for i in 0..<min(inputList.count, outputList.count) {
            let source = inputList[i]
            var destination = outputList[i]
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                continue
            }
            let byteCount = min(source.mDataByteSize, destination.mDataByteSize)
            memcpy(destinationData, sourceData, Int(byteCount))
            destination.mDataByteSize = byteCount
            outputList[i] = destination
        }
        return pcmBuffer
    }
}
