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

    @Option(
        name: .customLong("pair-code"),
        help: "6-digit pairing code: starts the iPhone/Watch peer listener on launch")
    var pairCode: String?

    @Option(
        name: .customLong("input-device"),
        help: "Pin mic input to this device UID if connected (optional; falls back to OS default)")
    var inputDeviceUID: String?

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

        // 音声の資産の確認には数秒かかることがある。その間にappがハングと判定しないよう、先に心拍を書く
        try? Heartbeat.write(to: CaptureStatePaths.processHeartbeatURL)

        let selectedLocale = Locale(identifier: locale)
        try await Transcriber.ensureAssets(locale: selectedLocale)

        let stdioControl = StdioControl()
        let session = ServeSession(
            outputDirectory: outputURL, owner: owner, sourceOption: sourceOption,
            locale: selectedLocale, control: stdioControl, device: DeviceIdentity.load(),
            archive: SessionArchive(), inputDeviceUID: inputDeviceUID)

        await stdioControl.send(
            .status(StatusEvent(recording: false, sources: [], outputDirectory: outputURL.path)))

        await session.resumeIfRecording()

        if let pairCode {
            await session.handle(.pairCode(pairCode))
        }

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            Task {
                await session.handle(.quit)
                Foundation.exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        sigintSource.resume()

        // アプリ側がterminate()の締め切りでProcess.terminate()（SIGTERM）に切り替えた場合も、
        // SIGINTと同じ経路でcleanにstopしてからexitする
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task {
                await session.handle(.quit)
                Foundation.exit(0)
            }
        }
        signal(SIGTERM, SIG_IGN)
        sigtermSource.resume()

        let heartbeatTask = Task {
            while !Task.isCancelled {
                try? Heartbeat.write(to: CaptureStatePaths.processHeartbeatURL)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        defer { heartbeatTask.cancel() }

        await stdioControl.send(.log("serve ready"))

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
