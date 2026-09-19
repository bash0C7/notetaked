import Foundation
import AVFoundation
import class NotetakeCore.RawAudioWriter
import enum NotetakeCore.CaptureSessionPaths

actor CaptureSessionRunner {
    private var micCapture: MicCapture?
    private var systemCapture: SystemAudioCapture?
    private var micWriter: RawAudioWriter?
    private var systemWriter: RawAudioWriter?
    private(set) var currentDirectory: URL?

    func start(directory: URL, sources: [String], inputDeviceUID: String?, onFallback: @escaping @Sendable () -> Void) throws {
        if currentDirectory == directory { return }
        stop()
        currentDirectory = directory
        if sources.contains("mic") {
            let writer = try RawAudioWriter(fileURL: CaptureSessionPaths.rawFileURL(sessionDirectory: directory, source: "mic"))
            let capture = MicCapture(pinnedUID: inputDeviceUID, onFallback: onFallback)
            try capture.start { [weak writer] buffer in
                Self.append(buffer: buffer, to: writer)
            }
            micWriter = writer
            micCapture = capture
        }
        if sources.contains("system") {
            let writer = try RawAudioWriter(fileURL: CaptureSessionPaths.rawFileURL(sessionDirectory: directory, source: "system"))
            let capture = try SystemAudioCapture()
            try capture.start { [weak writer] buffer in
                Self.append(buffer: buffer, to: writer)
            }
            systemWriter = writer
            systemCapture = capture
        }
    }

    func stop() {
        micCapture?.stop()
        systemCapture?.stop()
        micWriter?.close()
        systemWriter?.close()
        micCapture = nil
        systemCapture = nil
        micWriter = nil
        systemWriter = nil
        currentDirectory = nil
    }

    func isRunning(directory: URL) -> Bool {
        currentDirectory == directory
    }

    nonisolated private static func append(buffer: AVAudioPCMBuffer, to writer: RawAudioWriter?) {
        guard let writer, let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameLength * channelCount)
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = channelData[channel][frame]
            }
        }
        try? writer.write(sampleRate: buffer.format.sampleRate, channelCount: channelCount, samples: samples)
    }
}
