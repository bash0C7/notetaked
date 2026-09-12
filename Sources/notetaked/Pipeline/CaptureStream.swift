#if canImport(Speech)
import AVFoundation
import Foundation
import NotetakeCore

enum StreamEvent: Sendable {
    case volatile(String)
    case final(TranscriptPiece, levelDBFS: Double)
}

enum CaptureStreamError: Error {
    case sourceNotImplemented(Source)
}

/// capture → AudioConverter → Transcriber をつなぐpipeline
@available(macOS 26, iOS 26, *)
actor CaptureStream {
    private struct LevelSample {
        var startMS: Int64
        var endMS: Int64
        var dbfs: Double
    }

    private let capture: any AudioCapture
    private let transcriber: Transcriber
    private let converter: AudioConverter
    private var sampleTime: AVAudioFramePosition = 0
    private var levels: [LevelSample] = []
    /// 無音が続くとfinalが来ずlevelForPieceでlevelsが刈られないため、時間で刈る
    /// （直近2分だけ保持）。
    private static let levelRetentionMS: Int64 = 120_000
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<StreamEvent>.Continuation?

    let origin: Date

    init(source: Source, capture: any AudioCapture, locale: Locale) async throws {
        guard source != .watch else {
            throw CaptureStreamError.sourceNotImplemented(source)
        }
        self.capture = capture
        let origin = Date()
        self.origin = origin
        self.transcriber = try await Transcriber(locale: locale, origin: origin)
        self.converter = try AudioConverter(from: capture.format, to: transcriber.inputFormat)
    }

    func start() async throws -> AsyncStream<StreamEvent> {
        let pieces = try await transcriber.start()
        let originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
        let sampleRate = transcriber.inputFormat.sampleRate

        let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.bufferContinuation = bufferContinuation
        let converter = self.converter
        do {
            try capture.start { buffer in
                guard let converted = try? converter.convert(buffer) else { return }
                bufferContinuation.yield(converted)
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
                    let level = self.levelForPiece(piece)
                    eventContinuation.yield(.final(piece, levelDBFS: level))
                } else {
                    eventContinuation.yield(.volatile(piece.text))
                }
            }
            eventContinuation.finish()
        }

        return eventStream
    }

    /// capture.stop() → transcriber.finish()。残りのfinalはstreamに流れてから終了。
    /// finish()がthrowした場合もforwardTaskは必ずawaitする（未awaitのままだとevent streamが
    /// 終わるまで呼び出し側がwedgeしうる）: forwardTaskをcancelしeventContinuationをfinishしてから
    /// awaitし、rethrowする
    func stop() async throws {
        capture.stop()
        bufferContinuation?.finish()
        await feedTask?.value
        do {
            try await transcriber.finish()
        } catch {
            forwardTask?.cancel()
            eventContinuation?.finish()
            await forwardTask?.value
            throw error
        }
        await forwardTask?.value
    }

    private func ingest(
        _ buffer: sending AVAudioPCMBuffer, originMS: Int64, sampleRate: Double
    ) async {
        let frames = AVAudioFramePosition(buffer.frameLength)
        let startMS = originMS + Int64((Double(sampleTime) / sampleRate * 1000).rounded())
        let endMS = originMS + Int64((Double(sampleTime + frames) / sampleRate * 1000).rounded())
        let dbfs = AudioLevel.dbfs(buffer)
        levels.append(LevelSample(startMS: startMS, endMS: endMS, dbfs: dbfs))
        levels.removeAll { $0.endMS < startMS - Self.levelRetentionMS }
        await transcriber.feed(buffer, at: sampleTime)
        sampleTime += frames
    }

    /// pieceの時間範囲に入るbufferのdBFS平均。無ければ直近bufferのlevel
    private func levelForPiece(_ piece: TranscriptPiece) -> Double {
        let overlapping = levels.filter { $0.startMS < piece.endMS && $0.endMS > piece.startMS }
        let result: Double
        if overlapping.isEmpty {
            result = levels.last?.dbfs ?? -120
        } else {
            result = overlapping.map(\.dbfs).reduce(0, +) / Double(overlapping.count)
        }
        levels.removeAll { $0.endMS <= piece.endMS }
        return result
    }
}
#endif
