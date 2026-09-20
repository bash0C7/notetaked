import AVFoundation
import Foundation
import struct NotetakeCore.RawAudioFrame
import enum NotetakeCore.RawAudioReader

enum RawAudioReaderCaptureError: Error {
    case timedOutWaitingForFirstFrame
}

/// capture-daemonが書き続ける生audioファイルをtail読みし、`AudioCapture`として配信する。
/// `@unchecked Sendable`の根拠: `offset`・`currentFormat`等の可変stateはNSLockで保護され、
/// `pollTask`は所有者（CaptureStream actor）からのみ書き換えられる
final class RawAudioReaderCapture: AudioCapture, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var offset: Int
    private var pollTask: Task<Void, Never>?
    /// pinしたデバイスの切断でOS既定へフォールバックする等sampleRate/channelCountが変わっても、
    /// dropせずこのformatを再構築して配信を続ける（issue #18）
    private var currentFormat: AVAudioFormat
    /// `currentFormat`のsampleRate/channelCountが変わらずに続いている現segment内での、
    /// 累積sample frame数（丸め無し・正確値）
    private var segmentSampleFrames: Int64 = 0
    /// 現segmentが始まる前（過去の全formatセグメント分）に確定済みの累積ms
    private var segmentBaselineMS: Int64 = 0
    /// このinstanceが読み始めてから配信したaudioの累積ms（`segmentBaselineMS` + 現segment分。
    /// audioMsLog末尾との比較・trim判定に使う）
    private var cumulativeAudioMS: Int64 = 0
    /// このinstanceが読み始めてから配信したaudioの累積長（ms）と、その時点のoffsetの対応表。
    /// `handleFinal`がwall-clock（read位置）ではなくaudio時間軸でcheckpointを取れるようにする。
    /// frame単位で1 entryずつ記録する（poll batch単位だとresume直後の大きなbacklog一括読みで
    /// 粒度が粗くなり、finalizeのcheckpointがbacklog末尾まで先走ってしまうため）
    private var audioMsLog: [(audioMS: Int64, offset: Int)] = []

    /// capture側のnative format。sampleRate/channelCountが変われば追従する
    /// （`MicCapture.format`と同様、都度現在値を返すcomputed property）
    var format: AVAudioFormat {
        lock.lock()
        defer { lock.unlock() }
        return currentFormat
    }

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
        currentFormat = resolvedFormat!
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
        let (readFrom, startFormat, startSegmentFrames, startBaselineMS): (Int, AVAudioFormat, Int64, Int64) = {
            lock.lock()
            defer { lock.unlock() }
            return (offset, currentFormat, segmentSampleFrames, segmentBaselineMS)
        }()
        guard let (frames, newOffset) = try? RawAudioReader.readFrames(fileURL: fileURL, from: readFrom),
            !frames.isEmpty
        else { return }
        var runningOffsetCursor = readFrom
        var workingFormat = startFormat
        var segmentFrames = startSegmentFrames
        var baselineMS = startBaselineMS
        var newLogEntries: [(audioMS: Int64, offset: Int)] = []
        for frame in frames {
            let frameByteSize = 16 + frame.samples.count * 4
            runningOffsetCursor += frameByteSize
            // sampleRate/channelCountがそれまでのformatと食い違ったら、dropせず現segmentまでの
            // 経過msを確定してから新formatへ切り替えて処理を続ける（issue #18）
            if frame.sampleRate != workingFormat.sampleRate
                || AVAudioChannelCount(frame.channelCount) != workingFormat.channelCount
            {
                baselineMS += Self.ms(forSampleFrames: segmentFrames, sampleRate: workingFormat.sampleRate)
                segmentFrames = 0
                guard
                    let rebuilt = AVAudioFormat(
                        standardFormatWithSampleRate: frame.sampleRate, channels: AVAudioChannelCount(frame.channelCount))
                else { continue }
                workingFormat = rebuilt
            }
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: workingFormat, frameCapacity: AVAudioFrameCount(frame.samples.count / frame.channelCount))
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
            segmentFrames += Int64(frame.samples.count / channelCount)
            // sample frame数（丸め無し）からその時点の累積msを一度だけ算出してログに残す。
            // 1フレームごとにentryを積むことで、resume直後の大きなbacklog一括読みでも
            // 粒度が粗くならない
            let audioMS = baselineMS + Self.ms(forSampleFrames: segmentFrames, sampleRate: workingFormat.sampleRate)
            newLogEntries.append((audioMS, runningOffsetCursor))
        }
        lock.lock()
        offset = newOffset
        currentFormat = workingFormat
        segmentSampleFrames = segmentFrames
        segmentBaselineMS = baselineMS
        cumulativeAudioMS = baselineMS + Self.ms(forSampleFrames: segmentFrames, sampleRate: workingFormat.sampleRate)
        audioMsLog.append(contentsOf: newLogEntries)
        while audioMsLog.count > 1, let first = audioMsLog.first, cumulativeAudioMS - first.audioMS > 120_000 {
            audioMsLog.removeFirst()
        }
        lock.unlock()
    }

    private static func ms(forSampleFrames sampleFrames: Int64, sampleRate: Double) -> Int64 {
        Int64((Double(sampleFrames) / sampleRate * 1000).rounded())
    }
}
