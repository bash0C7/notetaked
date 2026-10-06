import AVFoundation
import Foundation
import NotetakeCore
import Testing
@testable import notetaked

/// 出力を任意のthreadから集める
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [LiveTranscription.Output] = []

    func append(_ output: LiveTranscription.Output) {
        lock.withLock { outputs.append(output) }
    }

    var errors: [String] {
        lock.withLock { outputs.compactMap { if case .error(let message) = $0 { message } else { nil } } }
    }

    var finals: [LiveTranscription.Piece] {
        lock.withLock { outputs.compactMap { if case .final(let piece) = $0 { piece } else { nil } } }
    }
}

private func appendSilence(to url: URL, samples: Int) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: CapturePCM.encode([Float](repeating: 0, count: samples)))
}

@Test(.timeLimit(.minutes(1))) func liveTranscriptionGivesWallClockTimesToPieces() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let speechURL = directory.appendingPathComponent("speech.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Kyoko", "-o", speechURL.path, "これはライブの文字起こしの確認です。"]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0)

    let file = try AVAudioFile(forReading: speechURL)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let resampler = MonoResampler()
    let speech = try resampler.convert(try #require(CapturedChunk(buffer: buffer, receivedAt: Date())))
        + resampler.flush()
    let pcmURL = CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: .system)
    try CapturePCM.encode([Float](repeating: 0, count: 16_000) + speech).write(to: pcmURL)
    let anchorMS: Int64 = 1_800_000_000_000
    let anchor = try CaptureMetaLine.anchor(CaptureAnchor(sample: 0, ms: anchorMS)).encodedLine()
    try Data((anchor + "\n").utf8).write(
        to: CaptureSessionPaths.metaURL(sessionDirectory: directory, source: .system))

    let live = try await LiveTranscription(
        source: .system, sessionDirectory: directory, locale: Locale(identifier: "ja-JP"), startAtEnd: false)
    let outputs = try await live.start()
    let collector = OutputCollector()
    let consumer = Task {
        for await output in outputs {
            collector.append(output)
        }
    }
    // 収録中と同じように無音を書き足し続けると、文字起こしが発話を確定させる
    let deadline = Date().addingTimeInterval(40)
    while collector.finals.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(200))
        try appendSilence(to: pcmURL, samples: 3_200)
    }
    await live.stop()
    await consumer.value

    let piece = try #require(collector.finals.first)
    #expect(piece.startMS >= anchorMS + 500)
    #expect(piece.endMS > piece.startMS)
    #expect(piece.input == .system)
    #expect(piece.levelDBFS > -60)
}

@Test(.timeLimit(.minutes(1))) func liveTranscriptionStopsBeforeAnyAudioArrives() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let live = try await LiveTranscription(
        source: .mic, sessionDirectory: directory, locale: Locale(identifier: "ja-JP"), startAtEnd: false)
    let outputs = try await live.start()
    let collector = OutputCollector()
    let consumer = Task {
        for await output in outputs {
            collector.append(output)
        }
    }
    try await Task.sleep(for: .milliseconds(300))
    await live.stop()
    await consumer.value
    // 自分で止めた時は、文字起こしが止まった失敗として伝えない
    #expect(collector.errors.isEmpty)
}

@Test func liveTranscriptionRejectsAnInputThatIsNotSixteenKilohertz() throws {
    try LiveTranscription.validateInputSampleRate(16_000)
    #expect(throws: LiveTranscription.SetupError.unsupportedSampleRate(48_000)) {
        try LiveTranscription.validateInputSampleRate(48_000)
    }
}
