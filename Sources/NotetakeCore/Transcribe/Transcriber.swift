#if canImport(Speech)
import AVFoundation
import CoreMedia
import Foundation
import Speech

public struct TranscriptPiece: Sendable, Equatable {
    public var text: String
    public var startMS: Int64  // origin + audio time
    public var endMS: Int64
    public var confidence: Double?  // runの transcriptionConfidence の平均。無ければnil
    public var isFinal: Bool
}

public enum TranscriberError: Error {
    case unsupportedLocale(Locale)
    case noCompatibleAudioFormat
}

@available(macOS 26, iOS 26, *)
public actor Transcriber {
    /// SpeechTranscriber.supportedLocales に無ければ throw。installedLocales に無ければ AssetInventory.assetInstallationRequest(supporting:) → downloadAndInstall()
    public static func ensureAssets(locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
            throw TranscriberError.unsupportedLocale(locale)
        }

        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier(.bcp47) == target }) else {
            return
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [
                transcriber
            ])
        else {
            return
        }
        FileHandle.standardError.write(
            Data("downloading \(locale.identifier) speech assets…\n".utf8))
        try await request.downloadAndInstall()
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let origin: Date
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    /// The error (if any) that ended the results-consumption loop in
    /// `start()`. Recorded here so `finish()` can surface it instead of
    /// silently swallowing it.
    private var resultsLoopError: Error?
    /// フィードされたフレーム数。0のままfinish()が呼ばれた場合、
    /// finalizeAndFinishThroughEndOfInput()は無音入力に対してハングするため、
    /// cancelAndFinishNow()で即座に終わらせる。
    /// UInt64（AVAudioFrameCountはUInt32のため、48kHzで約24.8時間の収録で
    /// overflowしうる。複数日にまたがる長時間収録に対応するためUInt64にする）。
    private var fedFrames: UInt64 = 0
    /// start()が返すAsyncStream<TranscriptPiece>を消費するresults-consumption task。
    /// cancelAndFinishNow()を呼んでも transcriber.results シーケンスが自然には終わらない
    /// ケースがあるため、finish()が強制終了経路を取った際にpiecesContinuationを直接finish
    /// して確実にstreamを閉じる。
    private var resultsTask: Task<Void, Never>?
    private var piecesContinuation: AsyncStream<TranscriptPiece>.Continuation?

    /// SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    public nonisolated let inputFormat: AVAudioFormat

    public init(locale: Locale, origin: Date) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [
                transcriber
            ])
        else {
            throw TranscriberError.noCompatibleAudioFormat
        }
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.origin = origin
        self.inputFormat = format
    }

    /// analyzer.start(inputSequence:) し、結果をTranscriptPieceに変換して流す
    public func start() async throws -> AsyncStream<TranscriptPiece> {
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation
        try await analyzer.start(inputSequence: inputStream)

        let results = transcriber.results
        let origin = self.origin
        let (stream, continuation) = AsyncStream<TranscriptPiece>.makeStream()
        self.piecesContinuation = continuation
        let task = Task {
            do {
                for try await result in results {
                    continuation.yield(Self.makePiece(from: result, origin: origin))
                }
            } catch {
                // results sequence ended with an error; record it so
                // finish() can surface it, then end the stream.
                self.recordResultsLoopError(error)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        self.resultsTask = task
        return stream
    }

    private func recordResultsLoopError(_ error: Error) {
        if resultsLoopError == nil {
            resultsLoopError = error
        }
    }

    /// bufferStartTime = CMTime(value: sampleTime, timescale: Int32(inputFormat.sampleRate))
    public func feed(_ buffer: sending AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
        let bufferStartTime = CMTime(
            value: sampleTime, timescale: Int32(inputFormat.sampleRate))
        fedFrames += UInt64(buffer.frameLength)
        inputContinuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: bufferStartTime))
    }

    /// 入力を閉じ finalizeAndFinishThroughEndOfInput() まで待つ。
    /// results消費loopで失敗が記録されていればそれをrethrowする。finalize自体が
    /// 失敗した場合は、loopの失敗（先に発生している）を優先してrethrowし、
    /// loopの失敗が無ければfinalizeの失敗をrethrowする。
    ///
    /// 一度もfeed()されていない場合、finalizeAndFinishThroughEndOfInput()は
    /// 無音入力に対してハングしうるため呼ばずcancelAndFinishNow()で即終了する。
    /// フレームが投入済みでも、finalizeが5秒以内に終わらなければタイムアウトとみなし
    /// cancelAndFinishNow()で打ち切る（タイムアウト自体はエラーにしない — それまでの
    /// finalは既にresultsループ経由で配送済みのため）。
    ///
    /// cancelAndFinishNow()を呼んでも transcriber.results シーケンスが自然には終わらない
    /// ことがあるため、この2つの強制終了経路では results-consumption task をcancelし、
    /// start()が返したAsyncStreamのcontinuationも直接finishして呼び出し側（CaptureStreamの
    /// forwardTask）がwedgeしないようにする。
    public func finish() async throws {
        inputContinuation?.finish()

        if fedFrames == 0 {
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            piecesContinuation?.finish()
            if let resultsLoopError {
                throw resultsLoopError
            }
            return
        }

        // finalizeAndFinishThroughEndOfInput()自体がキャンセルに応答しない可能性があるため、
        // TaskGroupのようにscope終了時に子taskの完了を暗黙に待つ構造は使わない。finalizeを
        // 独立したTaskで走らせ、5秒のTask.sleepと「先に終わった方」だけをAsyncStreamで受け取る
        // ことで、finalizeが残っていてもfinish()自体は5秒でreturnできるようにする。
        let finalizeTask = Task<Void, Error> {
            try await self.analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let (signal, signalContinuation) = AsyncStream<Bool>.makeStream()
        let watcherTask = Task {
            _ = try? await finalizeTask.value
            signalContinuation.yield(true)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            signalContinuation.yield(false)
        }

        var iterator = signal.makeAsyncIterator()
        let finishedInTime = await iterator.next() ?? false
        timeoutTask.cancel()
        watcherTask.cancel()

        if finishedInTime {
            do {
                try await finalizeTask.value
            } catch {
                throw resultsLoopError ?? error
            }
        } else {
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            piecesContinuation?.finish()
            FileHandle.standardError.write(
                Data("transcriber: finalize timed out after 5s; cancelled\n".utf8))
        }
        if let resultsLoopError {
            throw resultsLoopError
        }
    }

    private static func makePiece(from result: SpeechTranscriber.Result, origin: Date) -> TranscriptPiece {
        let text = result.text
        let originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
        let startMS = originMS + Int64((CMTimeGetSeconds(result.range.start) * 1000).rounded())
        let endMS = originMS + Int64((CMTimeGetSeconds(result.range.end) * 1000).rounded())

        var confidences: [Double] = []
        for run in text.runs {
            if let confidence = run.transcriptionConfidence {
                confidences.append(confidence)
            }
        }
        let confidence =
            confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)

        return TranscriptPiece(
            text: String(text.characters),
            startMS: startMS,
            endMS: endMS,
            confidence: confidence,
            isFinal: result.isFinal
        )
    }
}
#endif
