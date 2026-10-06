import AVFoundation
import Foundation
import NotetakeCore

/// 収録中、1つのsourceの生音声を末尾まで追いかけて文字起こしする。
/// 発話の時刻は`.meta.jsonl`のanchorから壁時計に直し、入力機器はdevice行から、音量は発話の範囲のsampleから求める
actor LiveTranscription {
    struct Piece: Sendable {
        let text: String
        let startMS: Int64
        let endMS: Int64
        let confidence: Double?
        let levelDBFS: Double
        let input: InputDevice
    }

    enum Output: Sendable {
        case volatile(String)
        case final(Piece)
        case log(String)
        /// 文字起こしが途中で止まるなど、以後の発話が出なくなる失敗
        case error(String)
    }

    enum SetupError: Error, Equatable {
        /// 生音声は16kHzで、文字起こしの入力とsample数が一致する前提で時刻を求めている
        case unsupportedSampleRate(Double)
    }

    /// 文字起こしの入力が生音声と同じsample rateか確かめる。違えば時刻の対応が崩れる
    static func validateInputSampleRate(_ rate: Double) throws {
        guard rate == Double(CapturePCM.sampleRate) else { throw SetupError.unsupportedSampleRate(rate) }
    }

    private static let pollInterval: Duration = .milliseconds(100)

    private let source: Source
    private let pcmURL: URL
    private let pcm: PCMTailReader
    private let meta: MetaTailReader
    private var locator: LivePieceLocator
    private let transcriber: Transcriber
    private let sourceFormat: AVAudioFormat
    private let converter: AudioConverter
    private var fedFrames: AVAudioFramePosition = 0
    private var pollTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var continuation: AsyncStream<Output>.Continuation?
    private var lastReportedError: String?
    private var stopping = false

    /// `startAtEnd`がtrueなら、生音声の現在の末尾から読む（serveが収録を途中から引き継ぐ時）
    init(source: Source, sessionDirectory: URL, locale: Locale, startAtEnd: Bool) async throws {
        self.source = source
        pcmURL = CaptureSessionPaths.pcmURL(sessionDirectory: sessionDirectory, source: source)
        let firstSample = startAtEnd ? PCMTailReader.sampleCount(of: pcmURL) : 0
        pcm = PCMTailReader(url: pcmURL, startSample: firstSample)
        meta = MetaTailReader(url: CaptureSessionPaths.metaURL(sessionDirectory: sessionDirectory, source: source))
        locator = LivePieceLocator(firstSample: firstSample)
        // 時刻の原点を1970年にすると、発話の時刻は文字起こしへ渡した最初のsampleからのmsになる
        transcriber = try await Transcriber(locale: locale, origin: Date(timeIntervalSince1970: 0))
        try Self.validateInputSampleRate(transcriber.inputFormat.sampleRate)
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(CapturePCM.sampleRate), channels: 1,
                interleaved: false)
        else {
            preconditionFailure("16kHz mono Float32 is always a valid format")
        }
        self.sourceFormat = sourceFormat
        converter = try AudioConverter(from: sourceFormat, to: transcriber.inputFormat)
    }

    func start() async throws -> AsyncStream<Output> {
        let pieces = try await transcriber.start()
        let (stream, continuation) = AsyncStream<Output>.makeStream()
        self.continuation = continuation
        forwardTask = Task {
            for await piece in pieces {
                self.accept(piece)
            }
            await self.reportResultsEnd()
        }
        pollTask = Task {
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        return stream
    }

    /// 文字起こしを打ち切る。最後の数秒の発話は出ないことがある
    func stop() async {
        stopping = true
        pollTask?.cancel()
        await pollTask?.value
        await transcriber.cancel()
        await forwardTask?.value
        continuation?.finish()
    }

    private func pollOnce() async {
        let samples: [Float]
        do {
            samples = try pcm.readNew()
        } catch {
            report("ライブの文字起こしで生音声を読めません: \(error)")
            return
        }
        // 書き手はsampleより先にそのanchorを書くため、sampleを読んだ後にmetaを読めば時刻が揃う。
        // metaを読めなくても、読んだsampleは文字起こしへ渡す
        do {
            for line in try meta.readNew() {
                locator.timeline.apply(line)
            }
        } catch {
            report("ライブの文字起こしで時刻の記録を読めません: \(error)")
        }
        guard !samples.isEmpty else { return }
        do {
            let converted = try converter.convert(try makeBuffer(samples))
            let frames = AVAudioFramePosition(converted.frameLength)
            await transcriber.feed(converted, at: fedFrames)
            fedFrames += frames
        } catch {
            // 渡せなかった分も数え、以後の発話の時刻とsampleの対応を保つ（入力は生音声と同じsample rate）
            fedFrames += AVAudioFramePosition(samples.count)
            report("ライブの文字起こしへ生音声を渡せません: \(error)")
        }
    }

    /// 結果が打ち切りでなく終わったら、以後の発話が出ないため失敗として伝える
    private func reportResultsEnd() async {
        guard !stopping else { return }
        let reason = await transcriber.resultsError().map { "\($0)" } ?? "結果が途中で終わりました"
        continuation?.yield(.error("\(source.rawValue)のライブの文字起こしが止まりました: \(reason)"))
    }

    private func accept(_ piece: TranscriptPiece) {
        guard piece.isFinal else {
            continuation?.yield(.volatile(piece.text))
            return
        }
        guard let location = locator.locate(startMS: piece.startMS, endMS: piece.endMS) else {
            report("時刻の基準点が無いため発話を出せません: \(piece.text)")
            return
        }
        let level: Double
        do {
            level = AudioLevel.dbfs(try PCMTailReader.samples(in: location.samples, of: pcmURL))
        } catch {
            report("発話の音量を読めません: \(error)")
            level = -120
        }
        let input = source == .system ? InputDevice.system : (location.input ?? InputDeviceProbe.current())
        continuation?.yield(
            .final(
                Piece(
                    text: piece.text, startMS: location.startMS, endMS: location.endMS,
                    confidence: piece.confidence, levelDBFS: level, input: input)))
    }

    private func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw AudioConverterError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// 同じ失敗が続く間は1度だけ伝える
    private func report(_ message: String) {
        guard message != lastReportedError else { return }
        lastReportedError = message
        continuation?.yield(.log(message))
    }
}
