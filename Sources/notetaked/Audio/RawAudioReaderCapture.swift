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
    /// このinstanceが読み始めてから配信したaudioの累積長（ms）と、その時点のoffsetの対応表。
    /// `handleFinal`がwall-clock（read位置）ではなくaudio時間軸でcheckpointを取れるようにする
    private var cumulativeAudioMS: Int64 = 0
    private var audioMsLog: [(audioMS: Int64, offset: Int)] = []

    var currentOffset: Int {
        lock.lock()
        defer { lock.unlock() }
        return offset
    }

    /// `targetMS`（このinstanceが読み始めてからのaudio経過ms）以前で最も遅いoffsetを返す。
    /// ログに無いほど古い（2分より前の）targetMSは、保持している最古のoffsetにfall backする
    /// （データ欠損よりreprocessingを選ぶ、安全側の丸め）
    func offset(atOrBeforeAudioMS targetMS: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !audioMsLog.isEmpty else { return offset }
        var result = audioMsLog.first!.offset
        for entry in audioMsLog {
            if entry.audioMS <= targetMS {
                result = entry.offset
            } else {
                break
            }
        }
        return result
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
        var batchDurationMS: Int64 = 0
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
            let channelCount = max(frame.channelCount, 1)
            let sampleFrameCount = frame.samples.count / channelCount
            if frame.sampleRate > 0 {
                batchDurationMS += Int64((Double(sampleFrameCount) / frame.sampleRate * 1000).rounded())
            }
        }
        lock.lock()
        offset = newOffset
        cumulativeAudioMS += batchDurationMS
        audioMsLog.append((cumulativeAudioMS, offset))
        while audioMsLog.count > 1, let first = audioMsLog.first, cumulativeAudioMS - first.audioMS > 120_000 {
            audioMsLog.removeFirst()
        }
        lock.unlock()
    }
}
