import AVFoundation
import Foundation
import NotetakeCore

enum RecorderError: Error {
    /// `start(locale:onPiece:)`が既に開始済みの状態でもう一度呼ばれた
    case alreadyRunning
}

/// マイク入力 → AudioConverter → Transcriber(SpeechAnalyzer) をつなぐ、iPhone側のcapture pipeline。
/// MacのCaptureStream（Sources/notetaked/Pipeline/CaptureStream.swift）と同じ
/// sampleTime/origin管理・`sending`によるbuffer受け渡しを踏襲するが、話者分離（Aligner）は無い
/// （iOSではまだ話者分離を送らないため、finalピースをそのまま返す）。
@available(iOS 26, *)
actor Recorder {
    /// installTapのcallback（real-time thread）からactorへ渡すための薄いラッパー。
    /// `AVAudioPCMBuffer`自体はこの1回のyieldでactor側へ所有が移り、callback側では以後触らない
    private struct CapturedBuffer: Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private var engine: AVAudioEngine?
    private var transcriber: Transcriber?
    private var converter: AudioConverter?
    private var sampleTime: AVAudioFramePosition = 0
    private var lastLevelDBFS: Double = -120

    private var bufferContinuation: AsyncStream<CapturedBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?

    /// マイクを開き、`locale`でTranscriberを起動する。finalなpieceのたびに`onPiece(piece, dbfs)`を呼ぶ
    /// （呼び出しは`Recorder`のactor context外、`onPiece`は`@Sendable`なので呼び出し側で自由に扱える）
    func start(
        locale: Locale, onPiece: @escaping @Sendable (TranscriptPiece, Double) -> Void
    ) async throws {
        guard engine == nil else { throw RecorderError.alreadyRunning }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)

        let origin = Date()
        let transcriber = try await Transcriber(locale: locale, origin: origin)
        let converter = try AudioConverter(from: tapFormat, to: transcriber.inputFormat)

        self.transcriber = transcriber
        self.converter = converter
        self.sampleTime = 0
        self.lastLevelDBFS = -120

        let pieces = try await transcriber.start()

        let (bufferStream, bufferContinuation) = AsyncStream<CapturedBuffer>.makeStream()
        self.bufferContinuation = bufferContinuation

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            bufferContinuation.yield(CapturedBuffer(buffer: buffer))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            bufferContinuation.finish()
            self.bufferContinuation = nil
            self.transcriber = nil
            self.converter = nil
            try? await transcriber.finish()
            throw error
        }

        self.engine = engine

        feedTask = Task {
            for await captured in bufferStream {
                await self.ingest(captured.buffer)
            }
        }

        forwardTask = Task {
            for await piece in pieces where piece.isFinal {
                let level = await self.currentLevelDBFS()
                onPiece(piece, level)
            }
        }
    }

    /// tapを外しengineを止め、transcriberを終了させる。呼び出しはpieceストリームが終わるまで待つ
    func stop() async throws {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        bufferContinuation?.finish()
        bufferContinuation = nil
        await feedTask?.value
        feedTask = nil

        let transcriber = self.transcriber
        self.transcriber = nil
        self.converter = nil

        do {
            try await transcriber?.finish()
        } catch {
            await forwardTask?.value
            forwardTask = nil
            throw error
        }
        await forwardTask?.value
        forwardTask = nil
    }

    private func ingest(_ buffer: sending AVAudioPCMBuffer) async {
        guard let converter, let transcriber else { return }
        guard let converted = try? converter.convert(buffer) else { return }
        lastLevelDBFS = AudioLevel.dbfs(converted)
        let frames = AVAudioFramePosition(converted.frameLength)
        await transcriber.feed(converted, at: sampleTime)
        sampleTime += frames
    }

    private func currentLevelDBFS() -> Double {
        lastLevelDBFS
    }
}
