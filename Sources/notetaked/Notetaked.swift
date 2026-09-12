import ArgumentParser

@main
struct Notetaked: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notetaked",
        abstract: "Notetake transcription daemon",
        version: "0.1.0",
        subcommands: []
    )
}
