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
            try await runCapture(MicCapture())
        case "system":
            try await runCapture(SystemAudioCapture())
        default:
            throw ValidationError("source must be mic or system")
        }
    }

    private func runCapture(_ capture: some AudioCapture) async throws {
        let counter = BufferCounter()

        let (dbfsStream, dbfsContinuation) = AsyncStream<Double>.makeStream()
        try capture.start { buffer in
            dbfsContinuation.yield(AudioLevel.dbfs(buffer))
        }

        let recordTask = Task {
            for await dbfs in dbfsStream {
                await counter.record(dbfs)
            }
        }

        try await Task.sleep(for: .seconds(seconds))
        capture.stop()
        dbfsContinuation.finish()
        await recordTask.value

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
