import ArgumentParser
import Foundation
import NotetakeCore

#if canImport(Speech)
import Speech
#endif

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the resident transcription daemon, controlled over stdin/stdout NDJSON"
    )

    @Option(name: .customLong("output"), help: "Directory to write session files into")
    var outputDirectory: String

    @Option(name: .customLong("owner"), help: "Owner label for the local (mic) speaker")
    var owner: String

    @Option(name: .customLong("source"), help: "Audio source: mic, system, or both")
    var source: String = "mic"

    @Option(name: .customLong("locale"), help: "BCP-47 locale to transcribe with")
    var locale: String = "ja-JP"

    @Option(name: .customLong("control"), help: "Control channel: stdio")
    var control: String = "stdio"

    @Flag(name: .customLong("start"), help: "Start recording immediately on launch")
    var startImmediately = false

    func run() async throws {
        #if canImport(Speech)
        guard #available(macOS 26, iOS 26, *) else {
            throw ValidationError("serve requires macOS 26 or later")
        }
        guard control == "stdio" else {
            throw ValidationError("--control must be stdio")
        }
        guard let sourceOption = ServeSession.SourceOption(rawValue: source) else {
            throw ValidationError("--source must be mic, system, or both")
        }
        try await runServe(sourceOption: sourceOption)
        #else
        throw ValidationError("Speech framework is unavailable on this platform")
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26, iOS 26, *)
    private func runServe(sourceOption: ServeSession.SourceOption) async throws {
        let outputURL = URL(fileURLWithPath: outputDirectory)
        try FileManager.default.createDirectory(
            at: outputURL, withIntermediateDirectories: true)

        let selectedLocale = Locale(identifier: locale)
        try await Transcriber.ensureAssets(locale: selectedLocale)

        let stdioControl = StdioControl()
        let device = DeviceIdentity.load()
        let session = ServeSession(
            outputDirectory: outputURL, owner: owner, sourceOption: sourceOption,
            locale: selectedLocale, control: stdioControl, device: device)

        await stdioControl.send(
            .status(StatusEvent(recording: false, sources: [], outputDirectory: outputURL.path)))

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            Task {
                await session.handle(.quit)
                Foundation.exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        sigintSource.resume()

        if startImmediately {
            await session.handle(.start)
        }

        for await command in await stdioControl.commands() {
            if case .quit = command {
                await session.handle(.quit)
                return
            }
            await session.handle(command)
        }

        // stdin reached EOF: behave as quit
        await session.handle(.quit)
    }
    #endif
}
