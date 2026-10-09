import ArgumentParser
import Foundation
import NotetakeCore

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Regenerate <prefix>.final.md (and <prefix>.context.md if signals exist) from a <prefix>.timed.jsonl file"
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
        let archive = SessionArchive()
        try await archive.renderFinal(prefix: prefix, in: directory)
        print(SessionFiles.finalURL(prefix: prefix, directory: directory).path)
        if FileManager.default.fileExists(atPath: SignalsFile.url(prefix: prefix, directory: directory).path) {
            try await archive.renderContext(prefix: prefix, in: directory)
            print(ContextRenderer.url(prefix: prefix, directory: directory).path)
        }
    }
}
