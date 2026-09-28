import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: Error {
    case noDisplayAvailable
    case formatUnavailable
}

/// ScreenCaptureKitのaudio captureで、system全体の音声（自process以外）をcaptureする。
///
/// macOS 27でCoreAudio Process Tap（`AudioHardwareCreateProcessTap` +
/// aggregate device）経由の収録が明確に劣化した音質（実機で「モゴモゴ・プチプチ」と確認）になる
/// 一方、QuickTime Playerの「システム音声を収録」（内部的にScreenCaptureKitの
/// audio captureを使う）は同じ機材・同時刻で問題なく収録できることが実機A/Bテストで確認された。
/// そのため取得手段そのものをProcess TapからScreenCaptureKitへ乗り換えた
/// （新規に画面収録権限＝Screen Recording TCC許可が必要）。
final class SystemAudioCapture: AudioCapture, @unchecked Sendable {
    // @unchecked Sendable: `handler`はstart()（stream起動より前）でのみ書き込まれ、
    // stream:didOutputSampleBuffer:ofType:はScreenCaptureKitが管理するsampleHandlerQueue上
    // でしか呼ばれない
    private static let sampleRate: Double = 48000
    private static let channelCount: AVAudioChannelCount = 2

    private let stream: SCStream
    /// `SCStreamOutput`はNSObjectプロトコルを要求するため、`SystemAudioCapture`本体をNSObject化
    /// せず専用のforwarderへ委譲する
    private let output: StreamOutputForwarder
    private var stopped = false

    let format: AVAudioFormat

    init() async throws {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate, channels: Self.channelCount)
        else {
            throw SystemAudioCaptureError.formatUnavailable
        }
        self.format = format

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(Self.sampleRate)
        configuration.channelCount = Int(Self.channelCount)
        configuration.excludesCurrentProcessAudio = true
        // 映像は使わないため最小構成にしてCPU/メモリ負荷を抑える
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream
        self.output = StreamOutputForwarder(format: format)

        try stream.addStreamOutput(
            output, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "io.github.bash0c7.notetaked.system-audio"))
    }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        output.handler = handler
        try await stream.startCapture()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let stream = self.stream
        Task { try? await stream.stopCapture() }
    }
}

/// `SCStreamOutput`はNSObjectプロトコルへの準拠を要求するが、`AVAudioEngine`ラップ等
/// 既存の`AudioCapture`実装と揃えて`SystemAudioCapture`自体は素のfinal classに保ちたいため、
/// callback受け口だけをこのNSObjectサブクラスへ分離する
private final class StreamOutputForwarder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let format: AVAudioFormat
    var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let handler else { return }
        guard let buffer = Self.makeBuffer(from: sampleBuffer, format: format) else { return }
        handler(buffer)
    }

    /// audioのCMSampleBufferをAVAudioPCMBufferへ変換する。sample dataはCMBlockBufferが
    /// 実体を持つためcopyせず、その保持をAVAudioPCMBufferのdeallocatorへ引き渡すことで
    /// buffer破棄まで生かし続ける
    private static func makeBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat)
        -> AVAudioPCMBuffer?
    {
        var blockBuffer: CMBlockBuffer?
        var bufferListSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &bufferListSizeNeeded, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, bufferListSizeNeeded > 0 else { return nil }

        let rawListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawListPointer.deallocate() }
        let audioBufferListPointer = rawListPointer.assumingMemoryBound(to: AudioBufferList.self)

        blockBuffer = nil
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: audioBufferListPointer,
            bufferListSize: bufferListSizeNeeded, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let retainedBlockBuffer = blockBuffer else { return nil }

        return AVAudioPCMBuffer(
            pcmFormat: format, bufferListNoCopy: audioBufferListPointer,
            deallocator: { _ in _ = retainedBlockBuffer })
    }
}
