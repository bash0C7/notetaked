import Foundation

public enum RawAudioReader {
    public static func readFrames(fileURL: URL, from offset: Int) throws -> (frames: [RawAudioFrame], newOffset: Int) {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return ([], offset)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let tail = handle.readDataToEndOfFile()
        var frames: [RawAudioFrame] = []
        var cursor = 0
        while let (frame, nextOffset) = RawAudioFrame.decode(from: tail, at: cursor) {
            frames.append(frame)
            cursor = nextOffset
        }
        return (frames, offset + cursor)
    }
}
