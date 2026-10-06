import ArgumentParser
import Foundation
import NotetakeCore

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Regenerate <prefix>.final.md from a <prefix>.timed.jsonl file"
    )

    @Argument(help: "Path to <prefix>.timed.jsonl")
    var timedPath: String

    func run() async throws {
        let timedURL = URL(fileURLWithPath: timedPath)
        let filename = timedURL.lastPathComponent
        guard filename.hasSuffix(".timed.jsonl") else {
            throw ValidationError("input file must end with .timed.jsonl")
        }
        let prefix = String(filename.dropLast(".timed.jsonl".count))

        let directory = timedURL.deletingLastPathComponent()
        try await SessionArchive().renderFinal(prefix: prefix, in: directory)
        let finalURL = SessionFiles.finalURL(prefix: prefix, directory: directory)
        print(finalURL.path)
    }
}
