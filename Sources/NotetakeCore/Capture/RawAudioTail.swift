import Foundation

/// capture-daemonが追記し続ける`.pcm`を読み進める。書きかけの端数byteは読まずに次回へ回す
public final class PCMTailReader {
    public let url: URL
    /// 次に返すsampleの番号
    public private(set) var nextSample: Int64
    private var handle: FileHandle?

    public init(url: URL, startSample: Int64) {
        self.url = url
        self.nextSample = startSample
    }

    deinit {
        try? handle?.close()
    }

    /// いまファイルにある完全なsampleの数。ファイルが無ければ0
    public static func sampleCount(of url: URL) -> Int64 {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value / Int64(CapturePCM.bytesPerSample)
    }

    /// 前回の続きから、書き終わったsampleを最大`maxSamples`個返す。ファイルがまだ無ければ空
    public func readNew(maxSamples: Int = 160_000) throws -> [Float] {
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            handle = try FileHandle(forReadingFrom: url)
        }
        guard let handle else { return [] }
        try handle.seek(toOffset: UInt64(nextSample) * UInt64(CapturePCM.bytesPerSample))
        guard let data = try handle.read(upToCount: maxSamples * CapturePCM.bytesPerSample) else { return [] }
        let samples = CapturePCM.decode(data)
        nextSample += Int64(samples.count)
        return samples
    }

    /// `range`のsampleを読む。ファイルの終わりを超える分は返さない
    public static func samples(in range: Range<Int64>, of url: URL) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound) * UInt64(CapturePCM.bytesPerSample))
        let data = try handle.read(upToCount: Int(range.count) * CapturePCM.bytesPerSample) ?? Data()
        return CapturePCM.decode(data)
    }
}

/// `.meta.jsonl`の新しい行を読む。改行で終わっていない最後の行は次回へ回す。
/// 解釈できない行は、書き手が書きかけで落ちた行なので飛ばす
public final class MetaTailReader {
    public let url: URL
    private var offset: UInt64 = 0
    private var handle: FileHandle?

    public init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    public func readNew() throws -> [CaptureMetaLine] {
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            handle = try FileHandle(forReadingFrom: url)
        }
        guard let handle else { return [] }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? CaptureMetaLine.decode(line: String($0)) }
    }
}

/// ライブの文字起こしの時刻（文字起こしへ最初に渡したsampleを0とするms）を、
/// 生音声のsample範囲と壁時計へ直す
public struct LivePieceLocator: Sendable {
    public struct Location: Equatable, Sendable {
        public var samples: Range<Int64>
        public var startMS: Int64
        public var endMS: Int64
        public var input: InputDevice?
    }

    /// 文字起こしへ最初に渡したsampleの番号
    public let firstSample: Int64
    public var timeline = CaptureTimeline()

    public init(firstSample: Int64) {
        self.firstSample = firstSample
    }

    /// anchorがまだ無ければnil
    public func locate(startMS: Int64, endMS: Int64) -> Location? {
        let start = firstSample + CapturePCM.samples(forMS: max(0, startMS))
        let end = max(start, firstSample + CapturePCM.samples(forMS: max(0, endMS)))
        guard let wallStart = timeline.ms(atSample: start), let wallEnd = timeline.ms(atSample: end) else {
            return nil
        }
        return Location(
            samples: start..<end, startMS: wallStart, endMS: max(wallStart, wallEnd),
            input: timeline.device(atSample: start))
    }
}
