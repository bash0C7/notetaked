import ArgumentParser
import Foundation
import NotetakeCore

struct Polish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "polish",
        abstract: "Polish a <prefix>.timed.jsonl transcript into <prefix>.polished.md using Foundation Models"
    )

    @Argument(help: "Path to <prefix>.timed.jsonl")
    var timedPath: String

    @Option(name: .customLong("output"), help: "Output path for the polished markdown (default: <prefix>.polished.md)")
    var outputPath: String?

    @Option(name: .customLong("max-characters"), help: "Maximum characters per chunk")
    var maxCharacters: Int = PolishChunker.defaultMaxCharacters

    func run() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            throw ValidationError("polish requires macOS 26 or later")
        }
        try await runPolish()
        #else
        throw ValidationError("FoundationModels framework is unavailable on this platform")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func runPolish() async throws {
        if let reason = Polisher.availabilityError() {
            throw ValidationError("Foundation Models unavailable: \(reason)")
        }

        let timedURL = URL(fileURLWithPath: timedPath)
        let text = try String(contentsOf: timedURL, encoding: .utf8)
        let records = NDJSON.decodeAll(text)
        guard case .session(let sessionRecord)? = records.first(where: {
            if case .session = $0 { return true } else { return false }
        }) else {
            throw ValidationError("no session record in \(timedPath)")
        }
        let recordedAt = Date(timeIntervalSince1970: Double(sessionRecord.started) / 1000)
        let utterances = Reconciler.fold(records)
        let turns = PolishChunker.turns(from: utterances)
        let chunks = PolishChunker.chunks(turns, maxCharacters: maxCharacters)

        if turns.isEmpty {
            FileHandle.standardError.write(Data("polish: no turns found, writing empty file\n".utf8))
        }

        var outputs: [[(speaker: String, text: String)]?] = []
        outputs.reserveCapacity(chunks.count)
        for (offset, chunk) in chunks.enumerated() {
            let index = offset + 1
            FileHandle.standardError.write(Data("polish: chunk \(index)/\(chunks.count)\n".utf8))
            let output = await Polisher.polish(chunk: chunk, index: index)
            outputs.append(output)
        }

        let polished = PolishChunker.merge(outputs: outputs, chunks: chunks)
        let markdown = PolishRenderer.markdown(polished, recordedAt: recordedAt, timeZone: .current)

        let outputURL = resolvedOutputURL(timedURL: timedURL)
        try Data(markdown.utf8).write(to: outputURL, options: .atomic)
        print(outputURL.path)
    }

    private func resolvedOutputURL(timedURL: URL) -> URL {
        if let outputPath {
            return URL(fileURLWithPath: outputPath)
        }
        let suffix = ".timed.jsonl"
        let filename = timedURL.lastPathComponent
        if filename.hasSuffix(suffix) {
            let prefix = String(filename.dropLast(suffix.count))
            return timedURL.deletingLastPathComponent().appendingPathComponent("\(prefix).polished.md")
        }
        return URL(fileURLWithPath: timedPath + ".polished.md")
    }
    #endif
}
