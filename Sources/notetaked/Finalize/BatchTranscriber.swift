#if canImport(Speech)
import AVFoundation
import CoreMedia
import Foundation
import NotetakeCore
import Speech

/// 文字起こしへ渡す入力。16kHz monoのFloat32を一定の長さずつ読み、文字起こしの入力形式へ変換する。
/// 入力は引き取り型で、文字起こしが次を求めた時にだけ読む。読む速さが文字起こしの速さに合うため、
/// 長い収録でも変換済みの音声が溜まらない
@available(macOS 26, *)
struct PCMChunkSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    /// 1回に読むsample数（10秒）
    static let chunkSamples = 10 * CapturePCM.sampleRate

    let source: MappedPCMSampleSource
    /// 文字起こしの入力形式。`AVAudioFormat`はSendableでないため、値だけを持ち、iteratorで作り直す
    let targetSampleRate: Double
    let targetCommonFormat: AVAudioCommonFormat
    let progress: @Sendable (Double) -> Void

    func makeAsyncIterator() -> Iterator {
        Iterator(sequence: self)
    }

    struct Iterator: AsyncIteratorProtocol {
        let sequence: PCMChunkSequence
        private var position = 0
        private var fedFrames: Int64 = 0
        private var converter: AudioConverter?

        init(sequence: PCMChunkSequence) {
            self.sequence = sequence
        }

        mutating func next() async throws -> AnalyzerInput? {
            let total = sequence.source.sampleCount
            guard position < total else { return nil }
            let converter = try makeConverter()
            let count = Swift.min(Self.chunkSamples, total - position)
            var samples = [Float](repeating: 0, count: count)
            try samples.withUnsafeMutableBufferPointer { buffer in
                try sequence.source.copySamples(into: buffer.baseAddress!, offset: position, count: count)
            }
            let converted = try converter.convert(try PCMBuffer.make(samples: samples, format: PCMBuffer.captureFormat()))
            let start = CMTime(value: fedFrames, timescale: Int32(CapturePCM.sampleRate))
            fedFrames += Int64(converted.frameLength)
            position += count
            sequence.progress(Double(position) / Double(total))
            return AnalyzerInput(buffer: converted, bufferStartTime: start)
        }

        private static var chunkSamples: Int { PCMChunkSequence.chunkSamples }

        private mutating func makeConverter() throws -> AudioConverter {
            if let converter { return converter }
            guard
                let target = AVAudioFormat(
                    commonFormat: sequence.targetCommonFormat, sampleRate: sequence.targetSampleRate, channels: 1,
                    interleaved: false)
            else {
                throw AudioConverterError.creationFailed
            }
            let created = try AudioConverter(from: PCMBuffer.captureFormat(), to: target)
            converter = created
            return created
        }
    }
}

/// 生音声の全sampleを先頭から文字起こしし、確定した結果ごとにrun（時間範囲付きのテキスト片）を返す
@available(macOS 26, *)
enum BatchTranscriber {
    /// 時刻は音声の先頭からのms。`progress`は読み終えた割合（0...1）
    static func transcribe(
        source: MappedPCMSampleSource, locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscribedPhrase] {
        // 一度もsampleを渡さないfinalizeは無音入力でハングするため、空の音声は文字起こししない
        guard source.sampleCount > 0 else { return [] }
        let transcriber = Transcriber.makeTranscriber(locale: locale, reportingOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noCompatibleAudioFormat
        }
        // 生音声と文字起こしの入力のsample rateが同じ前提で、時刻をsample番号へ直している
        guard format.sampleRate == Double(CapturePCM.sampleRate) else {
            throw BatchTranscriberError.unsupportedSampleRate(format.sampleRate)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputs = PCMChunkSequence(
            source: source, targetSampleRate: format.sampleRate, targetCommonFormat: format.commonFormat,
            progress: progress)
        let results = transcriber.results
        let collector = Task { () throws -> [TranscribedPhrase] in
            var phrases: [TranscribedPhrase] = []
            for try await result in results where result.isFinal {
                let piece = Transcriber.makePiece(from: result, origin: Date(timeIntervalSince1970: 0))
                phrases.append(TranscribedPhrase(runs: piece.runs, confidence: piece.confidence))
            }
            return phrases
        }
        do {
            try await analyzer.start(inputSequence: inputs)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }
}

enum BatchTranscriberError: Error, Equatable {
    case unsupportedSampleRate(Double)
}
#endif
