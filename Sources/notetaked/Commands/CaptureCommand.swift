import ArgumentParser
import AVFoundation
import Foundation
import NotetakeCore

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Capture audio and report buffer stats"
    )

    @Option(help: "Audio source: mic or system")
    var source: String = "mic"

    @Option(help: "Seconds to capture")
    var seconds: Double = 3

    func run() async throws {
        switch source {
        case "mic":
            try await runMicCapture()
        case "system":
            FileHandle.standardError.write(Data("not implemented\n".utf8))
            throw ExitCode(2)
        default:
            throw ValidationError("source must be mic or system")
        }
    }

    private func runMicCapture() async throws {
        let capture = MicCapture()
        let counter = BufferCounter()

        try capture.start { buffer in
            let dbfs = AudioLevel.dbfs(buffer)
            Task { await counter.record(dbfs) }
        }

        try await Task.sleep(for: .seconds(seconds))
        capture.stop()

        let (count, maxDBFS) = await counter.summary()
        print("buffers=\(count) max_dbfs=\(maxDBFS)")
    }
}

private actor BufferCounter {
    private var count = 0
    private var maxDBFS = -120.0

    func record(_ dbfs: Double) {
        count += 1
        maxDBFS = max(maxDBFS, dbfs)
    }

    func summary() -> (Int, Double) {
        (count, maxDBFS)
    }
}
