// Tests/NotetakeCoreTests/RawAudioWriterReaderTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func writerThenReaderRoundTripsAllFrames() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).raw")
    let writer = try RawAudioWriter(fileURL: url)
    try writer.write(sampleRate: 48000, channelCount: 1, samples: [0.1, 0.2])
    try writer.write(sampleRate: 48000, channelCount: 1, samples: [0.3, 0.4, 0.5])
    writer.close()

    let (frames, offset) = try RawAudioReader.readFrames(fileURL: url, from: 0)
    #expect(frames.count == 2)
    #expect(frames[0].samples == [0.1, 0.2])
    #expect(frames[1].samples == [0.3, 0.4, 0.5])
    #expect(offset == (try Data(contentsOf: url)).count)
}

@Test func readerResumesFromGivenOffset() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).raw")
    let writer = try RawAudioWriter(fileURL: url)
    try writer.write(sampleRate: 48000, channelCount: 1, samples: [1, 2])
    writer.close()
    let (_, offsetAfterFirst) = try RawAudioReader.readFrames(fileURL: url, from: 0)

    let writer2 = try RawAudioWriter(fileURL: url)
    try writer2.write(sampleRate: 48000, channelCount: 1, samples: [3, 4])
    writer2.close()

    let (frames, _) = try RawAudioReader.readFrames(fileURL: url, from: offsetAfterFirst)
    #expect(frames.count == 1)
    #expect(frames[0].samples == [3, 4])
}

@Test func readerReturnsEmptyWhenNoNewData() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).raw")
    let writer = try RawAudioWriter(fileURL: url)
    try writer.write(sampleRate: 48000, channelCount: 1, samples: [1])
    writer.close()
    let (_, offset) = try RawAudioReader.readFrames(fileURL: url, from: 0)
    let (frames, newOffset) = try RawAudioReader.readFrames(fileURL: url, from: offset)
    #expect(frames.isEmpty)
    #expect(newOffset == offset)
}

@Test func readerIgnoresTrailingPartialFrame() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).raw")
    let writer = try RawAudioWriter(fileURL: url)
    try writer.write(sampleRate: 48000, channelCount: 1, samples: [1, 2])
    writer.close()
    var data = try Data(contentsOf: url)
    data.append(Data([0, 1, 2]))
    try data.write(to: url)

    let (frames, newOffset) = try RawAudioReader.readFrames(fileURL: url, from: 0)
    #expect(frames.count == 1)
    #expect(newOffset == data.count - 3)
}
