import AVFoundation
import Foundation
import NotetakeCore

/// 取り込み（MicCaptureとSystemAudioCapture）が、音声と状態の変化を渡す先
protocol CaptureSink: AnyObject, Sendable {
    /// 音声のcallbackから呼ぶ。bufferの写しを取るだけで、変換と書き込みは記録用のqueueで行う
    func ingest(_ buffer: AVAudioPCMBuffer)
    func noteState(_ state: CaptureSourceState, reason: String?)
    func noteInput(_ device: InputDevice, fellBackFromPinned: Bool)
    /// 取り込みの途中で音声を失った失敗を、実状態の`lastError`へ残す
    func noteError(_ message: String)
}

/// 1つのsourceの生音声を書く。callbackから受け取ったbufferを直列のqueueへ渡し、
/// 16kHz monoへの変換、anchorの判定、`.pcm`と`.meta.jsonl`への書き込みをそのqueueで行う
final class SourceRecorder: CaptureSink, @unchecked Sendable {
    // @unchecked Sendable: 可変の状態はすべて`queue`の上でだけ読み書きする
    let source: Source
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    private let resampler = MonoResampler()
    private var anchorClock = AnchorClock()
    /// 書き込み先の収録。開けなかった時に開き直すため覚えておく
    private var directory: URL?
    private var lastOpenAttempt: Date?
    private var pcm: FileHandle?
    private var meta: FileHandle?
    private var writtenSamples: Int64 = 0
    private var input: InputDevice?
    private var deviceLinePending = false
    /// いまの`.meta.jsonl`へ最後に書いた状態。再試行のたびに同じ行を足さないために使う
    private var lastStateLine: StateLine?
    private var status: CaptureActualState.SourceStatus

    private static let openFailurePrefix = "書き込み先を開けません"

    private struct StateLine: Equatable {
        let state: CaptureSourceState
        let reason: String?
    }

    init(source: Source, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.now = now
        queue = DispatchQueue(label: "io.github.bash0c7.notetaked.recorder.\(source.rawValue)")
        status = CaptureActualState.SourceStatus(source: source, state: .off)
    }

    // MARK: - CaptureSink

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let receivedAt = now()
        guard let chunk = CapturedChunk(buffer: buffer, receivedAt: receivedAt) else {
            let description = "\(buffer.format)"
            queue.async { self.recordError("Float32でない音声は書けません: \(description)") }
            return
        }
        queue.async { self.write(chunk) }
    }

    func noteState(_ state: CaptureSourceState, reason: String?) {
        let at = now()
        queue.async {
            self.status.state = state
            self.status.reason = state == .retrying ? reason : nil
            let line = StateLine(state: state, reason: reason)
            guard line != self.lastStateLine else { return }
            self.lastStateLine = line
            self.appendMeta(.state(sample: self.writtenSamples, ms: Self.ms(at), state: state, reason: reason))
        }
    }

    func noteInput(_ device: InputDevice, fellBackFromPinned: Bool) {
        queue.async {
            self.input = device
            self.deviceLinePending = true
            self.status.input = device
            self.status.fellBackFromPinned = fellBackFromPinned
        }
    }

    func noteError(_ message: String) {
        queue.async { self.recordError(message) }
    }

    // MARK: - control

    /// 書き込み先を`directory`の収録へ切り替える。これより前に受け取ったbufferは前の収録へ、
    /// 後に受け取ったbufferは新しい収録へ書く。同じ収録を開き直した時は末尾へ追記する。
    /// `lastError`は開いた収録の失敗だけを表すよう空に戻してから、前の収録を閉じる
    func open(directory: URL) {
        queue.sync {
            status.lastError = nil
            closeFiles()
            self.directory = directory
            openFiles(at: now())
        }
    }

    /// 変換器に残った音声を書き出してファイルを閉じる。取り込みを止めた後に呼ぶ
    func close() {
        queue.sync {
            closeFiles()
            directory = nil
            status.state = .off
            status.reason = nil
        }
    }

    func snapshot() -> CaptureActualState.SourceStatus {
        queue.sync { status }
    }

    // MARK: - queue

    private func openFiles(at attemptTime: Date) {
        guard let directory else { return }
        lastOpenAttempt = attemptTime
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pcm = try Self.openForAppend(CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: source))
            let meta = try Self.openForAppend(CaptureSessionPaths.metaURL(sessionDirectory: directory, source: source))
            // 前のprocessが書きかけで終わっていても、追記がsampleと行の境目から始まるようにする
            let pcmEnd = try pcm.seekToEnd()
            let alignedEnd = pcmEnd - pcmEnd % UInt64(CapturePCM.bytesPerSample)
            if alignedEnd != pcmEnd {
                try pcm.truncate(atOffset: alignedEnd)
            }
            try Self.terminateLastLine(meta)
            self.pcm = pcm
            self.meta = meta
            writtenSamples = Int64(alignedEnd) / Int64(CapturePCM.bytesPerSample)
            anchorClock.reset()
            deviceLinePending = input != nil
            lastStateLine = nil
            if status.lastError?.hasPrefix(Self.openFailurePrefix) == true {
                status.lastError = nil
            }
        } catch {
            recordError("\(Self.openFailurePrefix): \(error)")
        }
    }

    private func write(_ chunk: CapturedChunk) {
        if pcm == nil || meta == nil {
            // 開けなかった書き込み先は、空きができた時などに書けるよう、1秒ごとに開き直す
            guard let lastOpenAttempt, chunk.receivedAt.timeIntervalSince(lastOpenAttempt) >= 1 else { return }
            openFiles(at: chunk.receivedAt)
        }
        guard let pcm, meta != nil else { return }
        let firstSample = writtenSamples + Int64(resampler.pendingSamples)
        let samples: [Float]
        do {
            samples = try resampler.convert(chunk)
        } catch {
            recordError("16kHzへ変換できません: \(error)")
            return
        }
        guard !samples.isEmpty else { return }
        let durationMS = Int64((Double(chunk.frameCount) / chunk.sampleRate * 1000).rounded())
        let startMS = Self.ms(chunk.receivedAt) - durationMS
        let anchor = anchorClock.anchor(forBufferStartingAt: firstSample, wallClockMS: startMS)
        do {
            try pcm.write(contentsOf: CapturePCM.encode(samples))
        } catch {
            recordError("生音声を書けません: \(error)")
            // 書きかけの端数を残すと、以後のsample番号がファイルの位置とずれる
            do {
                try pcm.truncate(atOffset: UInt64(writtenSamples) * UInt64(CapturePCM.bytesPerSample))
            } catch {
                recordError("書きかけの生音声を切り詰められません: \(error)")
            }
            // 書けなかった区間の後は、次に書けたbufferにanchorを付ける
            anchorClock.reset()
            return
        }
        writtenSamples += Int64(samples.count)
        // sampleを書いてから、そのanchorとdeviceの行を書く。間で落ちても、書いていないsampleを指すanchorが残って
        // 再起動後の時刻を誤らせることが無い
        if let anchor {
            appendMeta(.anchor(anchor))
        }
        if deviceLinePending, let input {
            appendMeta(.device(sample: firstSample, device: input))
            deviceLinePending = false
        }
    }

    private func closeFiles() {
        if let pcm {
            do {
                let tail = try resampler.flush()
                if !tail.isEmpty {
                    try pcm.write(contentsOf: CapturePCM.encode(tail))
                    writtenSamples += Int64(tail.count)
                }
            } catch {
                recordError("最後の音声を書けません: \(error)")
            }
        }
        for handle in [pcm, meta].compactMap({ $0 }) {
            do {
                try handle.close()
            } catch {
                recordError("ファイルを閉じられません: \(error)")
            }
        }
        pcm = nil
        meta = nil
    }

    private func appendMeta(_ line: CaptureMetaLine) {
        guard let meta else { return }
        do {
            try meta.write(contentsOf: Data((try line.encodedLine() + "\n").utf8))
        } catch {
            recordError("時刻情報を書けません: \(error)")
        }
    }

    /// 失敗を実状態の`lastError`に残す。直前と同じ失敗は`.meta.jsonl`へ書き直さない
    private func recordError(_ message: String) {
        guard status.lastError != message else { return }
        status.lastError = message
        guard let meta else { return }
        let line = CaptureMetaLine.state(sample: writtenSamples, ms: Self.ms(now()), state: status.state, reason: message)
        // この行を書けなくても、失敗は`lastError`で実状態に出る
        if let text = try? line.encodedLine() {
            try? meta.write(contentsOf: Data((text + "\n").utf8))
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func openForAppend(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path),
            !FileManager.default.createFile(atPath: url.path, contents: nil)
        {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try FileHandle(forUpdating: url)
    }

    /// 最後の行が改行で終わっていなければ改行を足す
    private static func terminateLastLine(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        let last = try handle.read(upToCount: 1)
        _ = try handle.seekToEnd()
        if last != Data([0x0A]) {
            try handle.write(contentsOf: Data([0x0A]))
        }
    }
}
