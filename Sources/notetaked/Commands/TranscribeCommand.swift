import ArgumentParser
import AVFoundation
import Foundation
import NotetakeCore

#if canImport(Speech)
import Speech
#endif

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file using SpeechAnalyzer"
    )

    @Argument(help: "Path to the audio file to transcribe")
    var audioFile: String

    @Option(help: "BCP-47 locale to transcribe with")
    var locale: String = "ja-JP"

    func run() async throws {
        #if canImport(Speech)
        guard #available(macOS 26, iOS 26, *) else {
            throw ValidationError("transcribe requires macOS 26 or later")
        }
        try await runTranscription()
        #else
        throw ValidationError("Speech framework is unavailable on this platform")
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26, iOS 26, *)
    private func runTranscription() async throws {
        let selectedLocale = Locale(identifier: locale)
        try await Transcriber.ensureAssets(locale: selectedLocale)

        let url = URL(fileURLWithPath: audioFile)
        let file = try AVAudioFile(forReading: url)
        let origin = Date()
        let transcriber = try await Transcriber(locale: selectedLocale, origin: origin)
        let converter = try AudioConverter(from: file.processingFormat, to: transcriber.inputFormat)

        let pieces = try await transcriber.start()
        let collector = Task {
            for await piece in pieces {
                if piece.isFinal {
                    print("\(piece.startMS)\t\(piece.endMS)\t\(piece.text)")
                } else {
                    FileHandle.standardError.write(Data("\(piece.text)\n".utf8))
                }
            }
        }

        let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.5)
        guard
            let readBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else {
            throw ValidationError("failed to allocate read buffer")
        }
        var sampleTime: AVAudioFramePosition = 0

        while file.framePosition < file.length {
            try file.read(into: readBuffer, frameCount: chunkFrames)
            if readBuffer.frameLength == 0 { break }
            let converted = try converter.convert(readBuffer)
            let convertedFrameLength = converted.frameLength
            await transcriber.feed(converted, at: sampleTime)
            sampleTime += AVAudioFramePosition(convertedFrameLength)
        }

        try await transcriber.finish()
        await collector.value
    }
    #endif
}
