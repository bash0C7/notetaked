import Foundation
import NotetakeCore
import Testing

@testable import notetaked

private func writePCM(_ samples: [Float], extraBytes: [UInt8] = []) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mapped-\(UUID().uuidString).pcm")
    try (CapturePCM.encode(samples) + Data(extraBytes)).write(to: url)
    return url
}

@Test func mappedSourceCountsWholeSamplesOnly() throws {
    let url = try writePCM([0.5, -1, 0.25], extraBytes: [1, 2])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try MappedPCMSampleSource(url: url).sampleCount == 3)
}

@Test func mappedSourceCopiesFromAnOffsetAndStopsAtTheEnd() throws {
    let url = try writePCM([0.5, -1, 0.25, 2])
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try MappedPCMSampleSource(url: url)

    var buffer = [Float](repeating: 9, count: 6)
    try buffer.withUnsafeMutableBufferPointer {
        try source.copySamples(into: $0.baseAddress!, offset: 1, count: 6)
    }
    #expect(buffer == [-1, 0.25, 2, 9, 9, 9])

    var untouched = [Float](repeating: 9, count: 2)
    try untouched.withUnsafeMutableBufferPointer {
        try source.copySamples(into: $0.baseAddress!, offset: 4, count: 2)
    }
    #expect(untouched == [9, 9])
}

@Test func mappedSourceReturnsSamplesInARangeClampedToTheFile() throws {
    let url = try writePCM([0.5, -1, 0.25, 2])
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try MappedPCMSampleSource(url: url)
    #expect(source.samples(in: 1..<3) == [-1, 0.25])
    #expect(source.samples(in: 2..<10) == [0.25, 2])
    #expect(source.samples(in: 5..<8).isEmpty)
}
