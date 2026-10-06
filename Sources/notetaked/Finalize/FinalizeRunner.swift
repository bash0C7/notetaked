#if canImport(Speech)
import Foundation
import NotetakeCore

enum FinalizeRunnerError: Error, CustomStringConvertible {
    case noRawAudio(URL)

    var description: String {
        switch self {
        case .noRawAudio(let directory):
            return "生音声がありません: \(directory.path)"
        }
    }
}

/// 進捗をstderrへ書く。serveがこの行を読んで、メニューの進捗と、進捗が途絶えたかの判断に使う。
/// 割合が上がった時だけ書く
final class FinalizeProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var throttles: [String: FinalizeProgressThrottle] = [:]

    func report(source: Source, stage: FinalizeProgress.Stage, fraction: Double) {
        let key = "\(source.rawValue)-\(stage.rawValue)"
        let percent: Int? = lock.withLock {
            var throttle = throttles[key] ?? FinalizeProgressThrottle()
            let percent = throttle.percent(forFraction: fraction)
            throttles[key] = throttle
            return percent
        }
        guard let percent else { return }
        Self.write(FinalizeProgress(source: source, stage: stage, percent: percent).line)
    }

    static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// 生音声ディレクトリの全sourceを、一括の文字起こしとオフライン話者分離で確定版の発話にする。
/// sourceは順に処理し、1つのsourceの中では文字起こしと話者分離を並行に走らせる
@available(macOS 26, *)
enum FinalizeRunner {
    /// 生音声にmicの入力機器の記録が無い時の入力機器
    private static let unknownInput = InputDevice(name: "不明", uid: "unknown", spatial: false)

    static func run(
        sessionDirectory: URL, run: Int, speakers: Int?, locale: Locale, reporter: FinalizeProgressReporter
    ) async throws -> FinalizeResult {
        let sources = [Source.mic, .system].filter {
            FileManager.default.fileExists(atPath: CaptureSessionPaths.pcmURL(sessionDirectory: sessionDirectory, source: $0).path)
        }
        guard !sources.isEmpty else { throw FinalizeRunnerError.noRawAudio(sessionDirectory) }
        try await Transcriber.ensureAssets(locale: locale)

        var results: [FinalizeSourceResult] = []
        for source in sources {
            results.append(
                try await runSource(
                    source, sessionDirectory: sessionDirectory, speakers: speakers, locale: locale, reporter: reporter))
        }
        return FinalizeResult(run: run, sources: results)
    }

    private static func runSource(
        _ source: Source, sessionDirectory: URL, speakers: Int?, locale: Locale, reporter: FinalizeProgressReporter
    ) async throws -> FinalizeSourceResult {
        let pcm = try MappedPCMSampleSource(
            url: CaptureSessionPaths.pcmURL(sessionDirectory: sessionDirectory, source: source))
        let timeline = CaptureTimeline(
            lines: try MetaTailReader(url: CaptureSessionPaths.metaURL(sessionDirectory: sessionDirectory, source: source))
                .readNew())
        guard pcm.sampleCount > 0 else {
            return FinalizeSourceResult(source: source, utterances: [], speakers: [])
        }

        async let phrases = BatchTranscriber.transcribe(source: pcm, locale: locale) {
            reporter.report(source: source, stage: .transcribe, fraction: $0)
        }
        async let diarization = OfflineSpeakerDiarization.run(source: pcm, speakers: speakers) {
            reporter.report(source: source, stage: .diarize, fraction: $0)
        }
        let (transcribed, diarized) = try await (phrases, diarization)

        return try FinalizeAssembler.sourceResult(
            source: source, phrases: transcribed, turns: diarized.turns, centroids: diarized.centroids,
            timeline: timeline, levelDBFS: { AudioLevel.dbfs(pcm.samples(in: $0)) }, fallbackInput: unknownInput)
    }
}
#endif
