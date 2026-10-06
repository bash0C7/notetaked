import AVFoundation
import CoreMedia
import Foundation
import NotetakeCore
import os
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: "取り込めるディスプレイがありません"
        }
    }
}

/// ScreenCaptureKitでsystem全体の音声（自process以外）を取り込む。
/// ScreenCaptureKitはディスプレイの消灯などでstreamを自ら止めるため、停止をdelegateで受け取り、
/// 5秒ごとにディスプレイの取得からstreamを作り直す。
/// 停止の知らせが無いまま音声のbufferが届かなくなった時のために、10秒届かなければstreamを作り直す
/// （ScreenCaptureKitは無音の間もbufferを届ける）
actor SystemAudioCapture: SourceCapture {
    private static let retryInterval: Duration = .seconds(5)
    private static let watchInterval: Duration = .seconds(5)
    private static let silenceLimit: Duration = .seconds(10)

    private var sink: (any CaptureSink)?
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var retryTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// streamを作るたびと止めるたびに進める。古いstreamから遅れて届いた停止の知らせを無視するために使う
    private var generation = 0

    func start(into sink: any CaptureSink) async {
        self.sink = sink
        sink.noteState(.retrying, reason: "ScreenCaptureKitへ接続しています")
        scheduleConnect(after: nil)
    }

    func stop() async {
        sink = nil
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        watchTask?.cancel()
        watchTask = nil
        output = nil
        guard let stream else { return }
        self.stream = nil
        // 既にScreenCaptureKitが止めたstreamではerrorになるが、止めるという目的は果たしている
        try? await stream.stopCapture()
    }

    private func scheduleConnect(after delay: Duration?) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func connect() async {
        guard let sink else { return }
        generation += 1
        let attempt = generation
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw SystemAudioCaptureError.noDisplayAvailable
            }
            let output = SystemAudioOutput(sink: sink) { [weak self] error in
                Task { await self?.streamStopped(error, generation: attempt) }
            }
            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                configuration: Self.configuration(), delegate: output)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            // 映像の出力が無いとScreenCaptureKitが毎秒error logを出すため、受け取って捨てる
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            guard attempt == generation else {
                await stopAbandoned(stream)
                return
            }
            self.stream = stream
            self.output = output
            sink.noteState(.recording, reason: nil)
            watchForSilence(of: output, generation: attempt)
        } catch {
            guard attempt == generation else { return }
            sink.noteState(.retrying, reason: error.localizedDescription)
            scheduleConnect(after: Self.retryInterval)
        }
    }

    /// 開始を待つ間に不要になったstreamを止める。止められないとcapture indicatorが残るため、失敗を残す
    private func stopAbandoned(_ stream: SCStream) async {
        do {
            try await stream.stopCapture()
        } catch {
            FileHandle.standardError.write(
                Data("capture-daemon: 不要になったsystem音声のstreamを止められません: \(error)\n".utf8))
        }
    }

    private func watchForSilence(of output: SystemAudioOutput, generation watched: Int) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled else { return }
                if output.timeSinceLastAudio() >= Self.silenceLimit {
                    await self?.rebuildSilentStream(generation: watched)
                    return
                }
            }
        }
    }

    private func rebuildSilentStream(generation watched: Int) async {
        guard watched == generation, let sink, let stream else { return }
        generation += 1
        self.stream = nil
        output = nil
        sink.noteState(.retrying, reason: "音声が届かないため、ScreenCaptureKitへ接続し直します")
        await stopAbandoned(stream)
        scheduleConnect(after: nil)
    }

    private func streamStopped(_ error: any Error, generation stopped: Int) {
        guard stopped == generation, let sink else { return }
        watchTask?.cancel()
        watchTask = nil
        stream = nil
        output = nil
        sink.noteState(.retrying, reason: error.localizedDescription)
        scheduleConnect(after: Self.retryInterval)
    }

    private static func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        // 映像は捨てるため、最小の大きさと頻度にする
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        return configuration
    }
}

/// ScreenCaptureKitのcallbackを受ける。`SCStreamOutput`と`SCStreamDelegate`はNSObjectを要求するため、
/// actorの外に置く
private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked Sendable: 不変の参照だけを持ち、ScreenCaptureKitは`queue`の上で音声を渡す
    let queue = DispatchQueue(label: "io.github.bash0c7.notetaked.system-audio")
    private let sink: any CaptureSink
    private let onStop: @Sendable (any Error) -> Void
    private let lastAudio: OSAllocatedUnfairLock<ContinuousClock.Instant>

    init(sink: any CaptureSink, onStop: @escaping @Sendable (any Error) -> Void) {
        self.sink = sink
        self.onStop = onStop
        lastAudio = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    }

    /// 最後に音声のbufferが届いてからの時間。届く前は、streamを作ってからの時間
    func timeSinceLastAudio() -> Duration {
        ContinuousClock.now - lastAudio.withLock { $0 }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lastAudio.withLock { $0 = ContinuousClock.now }
        // 長さ0のbufferは書く音声が無いだけで、失敗ではない
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let buffer = Self.makeBuffer(from: sampleBuffer) else {
            sink.noteError("system音声のbufferを取り出せません")
            return
        }
        sink.ingest(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
    }

    /// audioのCMSampleBufferをAVAudioPCMBufferへ包む。sampleはCMBlockBufferが持つため写さず、
    /// その保持をAVAudioPCMBufferの解放まで延ばす
    private static func makeBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
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
