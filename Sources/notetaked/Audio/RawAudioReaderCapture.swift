import AVFoundation
import Foundation
import struct NotetakeCore.RawAudioFrame
import enum NotetakeCore.RawAudioReader

enum RawAudioReaderCaptureError: Error {
    case timedOutWaitingForFirstFrame
}

/// capture-daemonが書き続ける生audioファイルをtail読みし、`AudioCapture`として配信する。
/// `@unchecked Sendable`の根拠: `offset`はNSLockで保護され、`pollTask`は所有者
/// （CaptureStream actor）からのみ書き換えられる
final class RawAudioReaderCapture: AudioCapture, @unchecked Sendable {
    let format: AVAudioFormat
    private let fileURL: URL
    private let lock = NSLock()
    private var offset: Int
    private var pollTask: Task<Void, Never>?

    var currentOffset: Int {
        lock.lock()
        defer { lock.unlock() }
        return offset
    }

    /// 最初のフレームが読めるまで0.1秒間隔でポーリングし、そのsampleRate/channelCountからformatを構築する
    /// （capture-daemon側が書き始めるまでの短い待ち合わせ）
    init(fileURL: URL, startOffset: Int, waitTimeout: TimeInterval = 10) async throws {
        self.fileURL = fileURL
        self.offset = startOffset
        let deadline = Date().addingTimeInterval(waitTimeout)
        var resolvedFormat: AVAudioFormat?
        while resolvedFormat == nil {
            let (frames, _) = try RawAudioReader.readFrames(fileURL: fileURL, from: startOffset)
            if let first = frames.first {
                resolvedFormat = AVAudioFormat(
                    standardFormatWithSampleRate: first.sampleRate, channels: AVAudioChannelCount(first.channelCount))
            } else if Date() > deadline {
                throw RawAudioReaderCaptureError.timedOutWaitingForFirstFrame
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        format = resolvedFormat!
    }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pollOnce(handler: handler)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let readFrom: Int = {
            lock.lock()
            defer { lock.unlock() }
            return offset
        }()
        guard let (frames, newOffset) = try? RawAudioReader.readFrames(fileURL: fileURL, from: readFrom),
            !frames.isEmpty
        else { return }
        for frame in frames {
            guard frame.sampleRate == format.sampleRate,
                AVAudioChannelCount(frame.channelCount) == format.channelCount
            else { continue }
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.samples.count / frame.channelCount))
            else { continue }
            buffer.frameLength = buffer.frameCapacity
            guard let channelData = buffer.floatChannelData else { continue }
            for i in 0..<Int(buffer.frameLength) {
                for channel in 0..<frame.channelCount {
                    channelData[channel][i] = frame.samples[i * frame.channelCount + channel]
                }
            }
            handler(buffer)
        }
        lock.lock()
        offset = newOffset
        lock.unlock()
    }
}
