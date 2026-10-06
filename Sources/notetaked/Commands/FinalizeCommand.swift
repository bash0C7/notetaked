import ArgumentParser
import Foundation
import NotetakeCore

struct Finalize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finalize",
        abstract: "Re-transcribe and diarize one session's raw audio into finalize.json (written next to the raw audio)"
    )

    @Argument(help: "Raw audio directory: <tmp>/notetake-capture/<prefix>")
    var directory: String

    @Option(name: .customLong("run"), help: "Finalization run number (1 for the first, then +1 for each re-finalize)")
    var runNumber: Int

    @Option(name: .customLong("speakers"), help: "Target number of speakers (not guaranteed)")
    var speakers: Int?

    @Option(name: .customLong("locale"), help: "BCP-47 locale to transcribe with")
    var locale: String = "ja-JP"

    func run() async throws {
        #if canImport(Speech)
        guard #available(macOS 26, iOS 26, *) else {
            throw ValidationError("finalize requires macOS 26 or later")
        }
        guard runNumber >= 1 else { throw ValidationError("--run must be 1 or greater") }
        if let speakers, speakers < 1 { throw ValidationError("--speakers must be 1 or greater") }
        try await runFinalize()
        #else
        throw ValidationError("Speech framework is unavailable on this platform")
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26, iOS 26, *)
    private func runFinalize() async throws {
        let sessionDirectory = URL(fileURLWithPath: directory)
        // 起動したprocess（serveかscript）が終わったら止める。続けても、起動し直された確定処理と重なるだけになる
        let parent = getppid()
        let parentWatcher = Task {
            while !Task.isCancelled {
                if getppid() != parent {
                    FinalizeProgressReporter.write("finalize: 起動したprocessが終わったため止めます")
                    Foundation.exit(1)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { parentWatcher.cancel() }

        let reporter = FinalizeProgressReporter()
        let result = try await FinalizeRunner.run(
            sessionDirectory: sessionDirectory, run: runNumber, speakers: speakers,
            locale: Locale(identifier: locale), reporter: reporter)
        try JSONFile.write(result, to: CaptureSessionPaths.finalizeResultURL(sessionDirectory: sessionDirectory))
        FinalizeProgressReporter.write(
            "finalize: 完了 run \(runNumber)（発話 \(result.sources.map(\.utterances.count).reduce(0, +))件）")
    }
    #endif
}
