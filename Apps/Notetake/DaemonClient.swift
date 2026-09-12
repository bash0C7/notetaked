import Foundation
import NotetakeCore

/// `notetaked serve --control stdio` をProcessとして起動し、stdin/stdoutをNDJSONで仲介するクライアント。
@MainActor
final class DaemonClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let onEvent: @MainActor (Event) -> Void
    private let onExit: @MainActor (Int32) -> Void
    private var stdoutBuffer = Data()

    init(
        executable: URL,
        arguments: [String],
        onEvent: @escaping @MainActor (Event) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) {
        self.onEvent = onEvent
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        process.terminationHandler = { [weak self] finishedProcess in
            let status = finishedProcess.terminationStatus
            Task { @MainActor in
                self?.onExit(status)
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consumeStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
        }
        try process.run()
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<newlineRange.upperBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            do {
                let event = try Event.decode(line: line)
                onEvent(event)
            } catch {
                let message = "DaemonClient: failed to decode line: \(line) (\(error))\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }

    func send(_ command: Command) {
        guard let line = try? command.encodedLine(), let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            let message = "DaemonClient: failed to write command: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    /// `quit`を送り2秒待ってからProcessを強制終了する。
    func terminate() {
        guard process.isRunning else { return }
        send(.quit)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
    }
}
