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
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        continuation.yield(Self.makePiece(from: result, origin: origin))
                    }
                } catch {
                    // results sequence ended with an error; end the stream
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// bufferStartTime = CMTime(value: sampleTime, timescale: Int32(inputFormat.sampleRate))
    public func feed(_ buffer: sending AVAudioPCMBuffer, at sampleTime: AVAudioFramePosition) {
        let bufferStartTime = CMTime(
            value: sampleTime, timescale: Int32(inputFormat.sampleRate))
        inputContinuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: bufferStartTime))
    }

    /// 入力を閉じ finalizeAndFinishThroughEndOfInput() まで待つ
    public func finish() async throws {
        inputContinuation?.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
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
