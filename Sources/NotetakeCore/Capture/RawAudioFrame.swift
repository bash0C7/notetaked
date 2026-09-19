import Foundation

public struct RawAudioFrame: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]

    public init(sampleRate: Double, channelCount: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }

    private static let headerSize = 16

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + samples.count * 4)
        var rate = sampleRate.bitPattern.littleEndian
        withUnsafeBytes(of: &rate) { data.append(contentsOf: $0) }
        var channels = UInt32(channelCount).littleEndian
        withUnsafeBytes(of: &channels) { data.append(contentsOf: $0) }
        var count = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(from data: Data, at offset: Int) -> (frame: RawAudioFrame, nextOffset: Int)? {
        guard offset >= data.startIndex, offset + headerSize <= data.endIndex else { return nil }
        let base = data.startIndex + offset
        let rateBits = data[base..<(base + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let sampleRate = Double(bitPattern: UInt64(littleEndian: rateBits))
        let channelsRaw = data[(base + 8)..<(base + 12)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let channelCount = Int(UInt32(littleEndian: channelsRaw))
        let countRaw = data[(base + 12)..<(base + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let sampleCount = Int(UInt32(littleEndian: countRaw))
        let payloadStart = base + headerSize
        let payloadEnd = payloadStart + sampleCount * 4
        guard payloadEnd <= data.endIndex else { return nil }
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        var cursor = payloadStart
        for _ in 0..<sampleCount {
            let bits = data[cursor..<(cursor + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            samples.append(Float(bitPattern: UInt32(littleEndian: bits)))
            cursor += 4
        }
        let frame = RawAudioFrame(sampleRate: sampleRate, channelCount: channelCount, samples: samples)
        return (frame, payloadEnd - data.startIndex)
    }
}
