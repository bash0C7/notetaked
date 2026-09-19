import Foundation

public final class RawAudioWriter {
    private let handle: FileHandle

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        _ = try handle.seekToEnd()
    }

    public func write(sampleRate: Double, channelCount: Int, samples: [Float]) throws {
        let frame = RawAudioFrame(sampleRate: sampleRate, channelCount: channelCount, samples: samples)
        try handle.write(contentsOf: frame.encoded())
    }

    public func close() {
        try? handle.close()
    }
}
