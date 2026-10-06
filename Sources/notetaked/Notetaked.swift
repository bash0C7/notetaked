import ArgumentParser

@main
struct Notetaked: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notetaked",
        abstract: "Notetake transcription daemon",
        version: "0.1.0",
        subcommands: [Serve.self, Render.self, Transcribe.self, CaptureDaemon.self, Polish.self, Finalize.self]
    )

    func run() async throws {
        throw CleanExit.helpRequest(self)
    }
}
