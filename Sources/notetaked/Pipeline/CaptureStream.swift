#if canImport(Speech)
import AVFoundation
import FluidAudio
import Foundation
import NotetakeCore
import NotetakeDiarization
import class NotetakeCore.AudioConverter
import class NotetakeDiarization.Diarizer

enum StreamEvent: Sendable {
    case volatile(String)
    case final(AlignedPiece, levelDBFS: Double)
    case log(String)
}

enum CaptureStreamError: Error {
    case sourceNotImplemented(Source)
    /// 16kHz mono Float32 formatの生成に失敗した（通常起こらないはずのAVAudioFormatの
    /// failable initializerの保険）
    case diarizerFormatUnavailable
}

/// capture → AudioConverter → Transcriber をつなぐpipeline。
/// `diarizerModels`が渡されていれば、同じcaptureからもう1系統16kHz monoへ変換し、
/// `Diarizer`で話者turnを求め、`Aligner`でTranscriberのfinal pieceを話者境界で分割する。
@available(macOS 26, iOS 26, *)
actor CaptureStream {
    private struct LevelSample {
        var startMS: Int64
        var endMS: Int64
        var dbfs: Double
    }

    /// captureコールバック（real-time thread）で1回のbufferから作る、2系統分の変換結果。
    /// `transcriber`は非Sendableな`AVAudioPCMBuffer`なので、この構造体はSendableにせず
    /// 従来どおり`sending`でactorへ渡す（変換結果は呼び出し側で二度と触らない）。
    /// `mono16k`はdiarizer用に、その場でFloat32 channel 0を`[Float]`へコピーしたもの。
    private struct Converted {
        let transcriber: AVAudioPCMBuffer
        let mono16k: [Float]?
    }

    private let capture: any AudioCapture
    private let transcriber: Transcriber
    private let converter: AudioConverter
    private let diarizer: Diarizer?
    private let diarizerConverter: AudioConverter?
    private var aligner = Aligner()
    /// diarizerのfeedが投げたエラーは(毎buffer起こりうるため)1回だけ`.log`で報告する
    private var diarizerErrorReported = false
    private var sampleTime: AVAudioFramePosition = 0
    private var levels: [LevelSample] = []
    /// 無音が続くとfinalが来ずlevelForPieceでlevelsが刈られないため、時間で刈る
    /// （直近2分だけ保持）。
    private static let levelRetentionMS: Int64 = 120_000
    private var bufferContinuation: AsyncStream<Converted>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    /// aligner.drain(nowMS:)をhold-limit経過だけで定期的に走らせるタイマー。
    /// 新しいbuffer/pieceが来ない間もhold-limit超過分が出るようにする。
    private var drainTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<StreamEvent>.Continuation?

    let origin: Date

    init(
        source: Source, capture: any AudioCapture, locale: Locale,
        diarizerModels: DiarizerModels?
    ) async throws {
        guard source != .watch else {
            throw CaptureStreamError.sourceNotImplemented(source)
        }
        self.capture = capture
        let origin = Date()
        self.origin = origin
        self.transcriber = try await Transcriber(locale: locale, origin: origin)
        self.converter = try AudioConverter(from: capture.format, to: transcriber.inputFormat)

        if let diarizerModels {
            guard
                let monoFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                    interleaved: false)
            else {
                throw CaptureStreamError.diarizerFormatUnavailable
            }
            self.diarizerConverter = try AudioConverter(from: capture.format, to: monoFormat)
            let originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
            self.diarizer = Diarizer(models: diarizerModels, originMS: originMS)
        } else {
            self.diarizerConverter = nil
            self.diarizer = nil
        }
    }

    func start() async throws -> AsyncStream<StreamEvent> {
        let pieces = try await transcriber.start()
        let originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
        let sampleRate = transcriber.inputFormat.sampleRate

        let (bufferStream, bufferContinuation) = AsyncStream<Converted>.makeStream()
        self.bufferContinuation = bufferContinuation
        let converter = self.converter
        let diarizerConverter = self.diarizerConverter
        do {
            try capture.start { buffer in
                guard let converted = try? converter.convert(buffer) else { return }
                var mono16k: [Float]?
                if let diarizerConverter,
                    let monoBuffer = try? diarizerConverter.convert(buffer),
                    let channelData = monoBuffer.floatChannelData
                {
                    let frameLength = Int(monoBuffer.frameLength)
                    mono16k = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                }
                bufferContinuation.yield(Converted(transcriber: converted, mono16k: mono16k))
            }
        } catch {
            bufferContinuation.finish()
            try? await transcriber.finish()
            throw error
        }

        feedTask = Task {
            for await converted in bufferStream {
                await self.ingest(converted, originMS: originMS, sampleRate: sampleRate)
            }
        }

        let (eventStream, eventContinuation) = AsyncStream<StreamEvent>.makeStream()
        self.eventContinuation = eventContinuation
        forwardTask = Task {
            for await piece in pieces {
                if piece.isFinal {
                    self.acceptFinal(piece)
                } else {
                    eventContinuation.yield(.volatile(piece.text))
                }
            }
        }

        drainTask = Task {
            while true {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                self.drainPending()
            }
        }

        return eventStream
    }

    /// capture.stop() → transcriber.finish()。残りのfinalはstreamに流れてから終了。
    /// finish()がthrowした場合もforwardTaskは必ずawaitする（未awaitのままだとevent streamが
    /// 終わるまで呼び出し側がwedgeしうる）: forwardTaskをcancelしてからawaitし、
    /// いずれの経路でもdiarizerのflush→alignerのflushを行ってからeventContinuationを
    /// finishし、rethrowする
    func stop() async throws {
        capture.stop()
        bufferContinuation?.finish()
        await feedTask?.value
        drainTask?.cancel()
        do {
            try await transcriber.finish()
        } catch {
            forwardTask?.cancel()
            await forwardTask?.value
            await finishAfterFlush()
            throw error
        }
        await forwardTask?.value
        await finishAfterFlush()
    }

    /// diarizerに残っている音声をflushしてalignerへ反映し、alignerに残っている保留piece
    /// 全部を今あるturnsだけで分割して出してから、event streamを終了する。
    private func finishAfterFlush() async {
        if let diarizer {
            if let output = try? await diarizer.flush() {
                aligner.add(turns: output.turns, coveredUntilMS: output.coveredUntilMS)
            }
        }
        for aligned in aligner.flush() {
            eventContinuation?.yield(
                .final(aligned, levelDBFS: levelForPiece(startMS: aligned.startMS, endMS: aligned.endMS)))
        }
        eventContinuation?.finish()
    }

    private func ingest(
        _ converted: sending Converted, originMS: Int64, sampleRate: Double
    ) async {
        let buffer = converted.transcriber
        let frames = AVAudioFramePosition(buffer.frameLength)
        let startMS = originMS + Int64((Double(sampleTime) / sampleRate * 1000).rounded())
        let endMS = originMS + Int64((Double(sampleTime + frames) / sampleRate * 1000).rounded())
        let dbfs = AudioLevel.dbfs(buffer)
        levels.append(LevelSample(startMS: startMS, endMS: endMS, dbfs: dbfs))
        levels.removeAll { $0.endMS < startMS - Self.levelRetentionMS }
        await transcriber.feed(buffer, at: sampleTime)
        sampleTime += frames

        guard let diarizer, let samples = converted.mono16k, !samples.isEmpty else { return }
        do {
            if let output = try await diarizer.feed(samples) {
                aligner.add(turns: output.turns, coveredUntilMS: output.coveredUntilMS)
                emitDrained(nowMS: Self.nowMS())
            }
        } catch {
            if !diarizerErrorReported {
                diarizerErrorReported = true
                eventContinuation?.yield(.log("diarizer feed failed: \(error)"))
            }
        }
    }

    /// 新しい音声もfinal pieceも来ない間、hold-limit超過分をタイマーから出すための入口
    private func drainPending() {
        emitDrained(nowMS: Self.nowMS())
    }

    /// transcriberのfinal pieceを受け取る。diarizerが無ければ即座に（話者未定のまま）
    /// StreamEvent.finalとして出す。あればalignerへ積んでからdrainする
    private func acceptFinal(_ piece: TranscriptPiece) {
        guard diarizer != nil else {
            let level = levelForPiece(startMS: piece.startMS, endMS: piece.endMS)
            let aligned = AlignedPiece(
                text: piece.text, startMS: piece.startMS, endMS: piece.endMS,
                confidence: piece.confidence, localSpeaker: nil, embedding: nil)
            eventContinuation?.yield(.final(aligned, levelDBFS: level))
            return
        }
        aligner.add(piece: AlignerInput(piece))
        emitDrained(nowMS: Self.nowMS())
    }

    private func emitDrained(nowMS: Int64) {
        for aligned in aligner.drain(nowMS: nowMS) {
            eventContinuation?.yield(
                .final(aligned, levelDBFS: levelForPiece(startMS: aligned.startMS, endMS: aligned.endMS)))
        }
    }

    private static func nowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// [startMS, endMS)に入るbufferのdBFS平均。無ければ直近bufferのlevel
    private func levelForPiece(startMS: Int64, endMS: Int64) -> Double {
        let overlapping = levels.filter { $0.startMS < endMS && $0.endMS > startMS }
        let result: Double
        if overlapping.isEmpty {
            result = levels.last?.dbfs ?? -120
        } else {
            result = overlapping.map(\.dbfs).reduce(0, +) / Double(overlapping.count)
        }
        levels.removeAll { $0.endMS <= endMS }
        return result
    }
}
#endif
