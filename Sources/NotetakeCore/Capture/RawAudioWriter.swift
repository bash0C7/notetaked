import Foundation

/// @unchecked Sendable: 呼び出し元(CaptureSessionRunner)はwriterごとに単一のaudio捕捉スレッドから
/// のみ`write`を呼び、`close`は同じcapture(`stop()`が同期的にhardware捕捉を止めた後)からのみ呼ぶため、
/// MicCapture/SystemAudioCaptureと同様に並行アクセスが発生しない
public final class RawAudioWriter: @unchecked Sendable {
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
