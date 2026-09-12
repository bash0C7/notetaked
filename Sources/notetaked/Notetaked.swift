import ArgumentParser

@main
struct Notetaked: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notetaked",
        abstract: "Notetake transcription daemon",
        version: "0.1.0",
        subcommands: [Transcribe.self]
    )

    func run() async throws {
        throw CleanExit.helpRequest(self)
    }
}
