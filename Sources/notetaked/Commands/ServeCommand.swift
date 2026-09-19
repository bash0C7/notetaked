import ArgumentParser
import Foundation
import NotetakeCore

#if canImport(Speech)
import NotetakeDiarization
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

    @Flag(
        name: .customLong("diarize"), inversion: .prefixedNo,
        help: "Run speaker diarization (default on)")
    var diarize = true

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

        let selectedLocale = Locale(identifier: locale)
        try await Transcriber.ensureAssets(locale: selectedLocale)

        let stdioControl = StdioControl()
        let device = DeviceIdentity.load()
        let profileStore = SpeakerProfileStore.default()
        let registry = SpeakerRegistry(profiles: profileStore.load())

        let session: ServeSession
        if diarize {
            let progressReporter = DiarizerModelProgressReporter()
            do {
                let models = try await Diarizer.prepareModels { fraction in
                    Task {
                        if let step = await progressReporter.reportedStep(for: fraction) {
                            await stdioControl.send(.log("diarizer models: \(step * 10)%"))
                        }
                    }
                }
                await stdioControl.send(.log("diarizer ready"))
                session = ServeSession(
                    outputDirectory: outputURL, owner: owner, sourceOption: sourceOption,
                    locale: selectedLocale, control: stdioControl, device: device,
                    diarizerModels: models, registry: registry, profileStore: profileStore,
                    inputDeviceUID: inputDeviceUID)
            } catch {
                await stdioControl.send(.error("diarizer unavailable: \(error)"))
                session = ServeSession(
                    outputDirectory: outputURL, owner: owner, sourceOption: sourceOption,
                    locale: selectedLocale, control: stdioControl, device: device,
                    diarizerModels: nil, registry: registry, profileStore: profileStore,
                    inputDeviceUID: inputDeviceUID)
            }
        } else {
            session = ServeSession(
                outputDirectory: outputURL, owner: owner, sourceOption: sourceOption,
                locale: selectedLocale, control: stdioControl, device: device,
                diarizerModels: nil, registry: registry, profileStore: profileStore,
                inputDeviceUID: inputDeviceUID)
        }

        await stdioControl.send(
            .status(StatusEvent(recording: false, sources: [], outputDirectory: outputURL.path)))

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

#if canImport(Speech)
/// `Diarizer.prepareModels(progress:)`のprogress closureは高頻度に呼ばれうるため、
/// `.log`イベントを10%刻みでしか送らないよう直近の刻みを覚えておくactor
/// （closure自体は`@Sendable`な同期関数で、直接`await`できないため、呼び出し側が
/// `Task { await ... }`でこのactorへ問い合わせる）
private actor DiarizerModelProgressReporter {
    private var lastStep = -1

    /// fraction（0...1）から10%刻みのstepを求め、前回報告済みのstepと同じなら`nil`
    /// （報告不要）、新しいstepなら報告用に`0...10`を返す
    func reportedStep(for fraction: Double) -> Int? {
        let clamped = min(max(fraction, 0), 1)
        let step = Int((clamped * 10).rounded(.down))
        guard step != lastStep else { return nil }
        lastStep = step
        return step
    }
}
#endif
