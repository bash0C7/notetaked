import ArgumentParser
import Foundation
import struct NotetakeCore.CaptureControlChannel
import enum NotetakeCore.CaptureCommand
import enum NotetakeCore.CaptureEvent
import enum NotetakeCore.CaptureStatePaths
import enum NotetakeCore.Heartbeat

struct CaptureDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-daemon",
        abstract: "Resident audio-only capture process, isolated from transcription/control")

    func run() async throws {
        let runner = CaptureSessionRunner()
        let commandChannel = CaptureControlChannel<CaptureCommand>(fileURL: CaptureStatePaths.captureCommandURL)
        let eventChannel = CaptureControlChannel<CaptureEvent>(fileURL: CaptureStatePaths.captureEventURL)

        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task {
                await runner.stop()
                Foundation.exit(0)
            }
        }
        sigtermSource.resume()

        var lastCommandSeenAt: Date?
        while true {
            try? Heartbeat.write(to: CaptureStatePaths.captureHeartbeatURL)
            if let (command, seenAt) = commandChannel.poll(after: lastCommandSeenAt) {
                lastCommandSeenAt = seenAt
                await handle(command, runner: runner, eventChannel: eventChannel)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func handle(
        _ command: CaptureCommand, runner: CaptureSessionRunner,
        eventChannel: CaptureControlChannel<CaptureEvent>
    ) async {
        switch command {
        case .startSession(let directory, let sources, let inputDeviceUID):
            let directoryURL = URL(fileURLWithPath: directory)
            do {
                try await runner.start(directory: directoryURL, sources: sources, inputDeviceUID: inputDeviceUID) {
                    try? eventChannel.send(.inputFallback)
                }
                try? eventChannel.send(.started(directory: directory))
            } catch {
                try? eventChannel.send(.error("\(error)"))
            }
        case .stopSession:
            await runner.stop()
            try? eventChannel.send(.stopped)
        case .quit:
            await runner.stop()
            Foundation.exit(0)
        }
    }
}
