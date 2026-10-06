import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func pcmTailReaderLeavesPartialSamplesForTheNextRead() throws {
    let directory = temporaryDirectory("pcm")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("mic.pcm")
    let reader = PCMTailReader(url: url, startSample: 0)

    #expect(try reader.readNew() == [])

    let encoded = CapturePCM.encode([0.25, 0.5, 0.75])
    try encoded.prefix(10).write(to: url)
    #expect(try reader.readNew() == [0.25, 0.5])
    #expect(reader.nextSample == 2)

    try encoded.write(to: url)
    #expect(try reader.readNew() == [0.75])
    #expect(PCMTailReader.sampleCount(of: url) == 3)
    #expect(try PCMTailReader.samples(in: 1..<5, of: url) == [0.5, 0.75])
}

@Test func pcmTailReaderCanStartAtTheEnd() throws {
    let directory = temporaryDirectory("pcm")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("system.pcm")
    try CapturePCM.encode([0.1, 0.2]).write(to: url)

    let reader = PCMTailReader(url: url, startSample: PCMTailReader.sampleCount(of: url))
    #expect(try reader.readNew() == [])

    let handle = try FileHandle(forWritingTo: url)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: CapturePCM.encode([0.3]))
    try handle.close()
    #expect(try reader.readNew() == [0.3])
}

@Test func metaTailReaderWaitsForTheLineEndAndSkipsBrokenLines() throws {
    let directory = temporaryDirectory("meta")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("mic.meta.jsonl")
    let reader = MetaTailReader(url: url)

    #expect(try reader.readNew() == [])

    let first = try CaptureMetaLine.anchor(CaptureAnchor(sample: 0, ms: 1)).encodedLine()
    let second = try CaptureMetaLine.anchor(CaptureAnchor(sample: 16, ms: 2)).encodedLine()
    try Data("\(first)\nbroken\n\(second.prefix(5))".utf8).write(to: url)
    #expect(try reader.readNew() == [.anchor(CaptureAnchor(sample: 0, ms: 1))])

    try Data("\(first)\nbroken\n\(second)\n".utf8).write(to: url)
    #expect(try reader.readNew() == [.anchor(CaptureAnchor(sample: 16, ms: 2))])
}

@Test func livePieceLocatorMapsTranscriberTimeToSamplesAndWallClock() {
    let headset = InputDevice(name: "ヘッドセット", uid: "headset", spatial: false)
    var locator = LivePieceLocator(firstSample: 160_000)
    #expect(locator.locate(startMS: 0, endMS: 1_000) == nil)

    locator.timeline.apply(.anchor(CaptureAnchor(sample: 0, ms: 1_000_000)))
    locator.timeline.apply(.anchor(CaptureAnchor(sample: 176_000, ms: 1_100_000)))
    locator.timeline.apply(.device(sample: 0, device: headset))

    let location = locator.locate(startMS: 500, endMS: 1_500)
    #expect(location?.samples == 168_000..<184_000)
    #expect(location?.startMS == 1_010_500)
    #expect(location?.endMS == 1_100_500)
    #expect(location?.input == headset)
}
