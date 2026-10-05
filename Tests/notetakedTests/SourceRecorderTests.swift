import AVFoundation
import Foundation
import Testing
import NotetakeCore
@testable import notetaked

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

/// テストから受け取り時刻を進める時計
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func set(_ date: Date) { lock.withLock { current = date } }
}

/// 指定したformatで、全sampleが`value`のbufferを作る
private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, value: Float = 0.25) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(channels) {
        for frame in 0..<frames {
            buffer.floatChannelData![channel][frame] = value
        }
    }
    return buffer
}

private func metaLines(_ directory: URL, _ source: Source) throws -> [CaptureMetaLine] {
    let text = try String(contentsOf: CaptureSessionPaths.metaURL(sessionDirectory: directory, source: source), encoding: .utf8)
    return try text.split(separator: "\n").map { try CaptureMetaLine.decode(line: String($0)) }
}

private func sampleCount(_ directory: URL, _ source: Source) -> Int64 {
    let url = CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: source)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    return (size?.int64Value ?? 0) / Int64(CapturePCM.bytesPerSample)
}

/// 100msのbufferを`count`個、実時間どおりの受け取り時刻で渡す
private func feed(
    _ recorder: SourceRecorder, clock: TestClock, from start: Date, count: Int,
    sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2
) {
    let frames = Int(sampleRate / 10)
    for index in 0..<count {
        clock.set(start.addingTimeInterval(Double(index + 1) * 0.1))
        recorder.ingest(makeBuffer(sampleRate: sampleRate, channels: channels, frames: frames))
    }
}

@Test func resamplerKeepsTheSampleCountAcrossBuffers() throws {
    let resampler = MonoResampler()
    var total = 0
    for _ in 0..<100 {
        let chunk = CapturedChunk(
            sampleRate: 48_000, channelCount: 2, interleaved: false,
            samples: [Float](repeating: 0.5, count: 9_600), receivedAt: Date())
        total += try resampler.convert(chunk).count
    }
    total += try resampler.flush().count
    #expect(abs(total - 160_000) <= 2)
}

@Test func resamplerPassesSixteenKilohertzThroughAndAveragesChannels() throws {
    let resampler = MonoResampler()
    let interleaved = CapturedChunk(
        sampleRate: 16_000, channelCount: 2, interleaved: true, samples: [1, 0, 0.5, 0.5], receivedAt: Date())
    #expect(try resampler.convert(interleaved) == [0.5, 0.5])
    let planar = CapturedChunk(
        sampleRate: 16_000, channelCount: 2, interleaved: false, samples: [1, 0.5, 0, 0.5], receivedAt: Date())
    #expect(try resampler.convert(planar) == [0.5, 0.5])
}

@Test func recorderWritesSixteenKilohertzMonoWithAnchorAndDevice() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .mic, now: { clock.now })
    let builtIn = InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false)

    recorder.open(directory: directory)
    recorder.noteInput(builtIn, fellBackFromPinned: false)
    feed(recorder, clock: clock, from: start, count: 10)
    recorder.close()

    #expect(abs(sampleCount(directory, .mic) - 16_000) <= 2)
    let lines = try metaLines(directory, .mic)
    #expect(lines.first == .anchor(CaptureAnchor(sample: 0, ms: 1_800_000_000_000)))
    #expect(lines.contains(.device(sample: 0, device: builtIn)))
    #expect(lines.filter { if case .anchor = $0 { true } else { false } }.count == 1)
}

@Test func recorderAnchorsAGapButNotJitter() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .system, now: { clock.now })

    recorder.open(directory: directory)
    feed(recorder, clock: clock, from: start, count: 5)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.6), count: 5)
    feed(recorder, clock: clock, from: start.addingTimeInterval(61), count: 5)
    recorder.close()

    let anchors = try metaLines(directory, .system).compactMap { line -> CaptureAnchor? in
        if case .anchor(let anchor) = line { anchor } else { nil }
    }
    #expect(anchors == [
        CaptureAnchor(sample: 0, ms: 1_800_000_000_000), CaptureAnchor(sample: 16_000, ms: 1_800_000_061_000),
    ])
}

@Test func recorderAnchorsTheFirstSampleAfterAFormatChangeAndGap() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .mic, now: { clock.now })

    recorder.open(directory: directory)
    feed(recorder, clock: clock, from: start, count: 10, sampleRate: 24_000, channels: 1)
    feed(recorder, clock: clock, from: start.addingTimeInterval(5), count: 10, sampleRate: 44_100, channels: 1)
    recorder.close()

    let anchors = try metaLines(directory, .mic).compactMap { line -> CaptureAnchor? in
        if case .anchor(let anchor) = line { anchor } else { nil }
    }
    #expect(anchors == [
        CaptureAnchor(sample: 0, ms: 1_800_000_000_000), CaptureAnchor(sample: 16_000, ms: 1_800_000_005_000),
    ])
    #expect(abs(sampleCount(directory, .mic) - 32_000) <= 4)
}

@Test func recorderSwitchesDirectoriesWithoutLosingSamples() throws {
    let first = temporaryDirectory("recorder-a")
    let second = temporaryDirectory("recorder-b")
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .mic, now: { clock.now })
    let builtIn = InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false)

    recorder.open(directory: first)
    recorder.noteInput(builtIn, fellBackFromPinned: false)
    feed(recorder, clock: clock, from: start, count: 10)
    recorder.open(directory: second)
    feed(recorder, clock: clock, from: start.addingTimeInterval(1), count: 10)
    recorder.close()

    #expect(abs(sampleCount(first, .mic) + sampleCount(second, .mic) - 32_000) <= 2)
    let lines = try metaLines(second, .mic)
    #expect(lines.prefix(2) == [.anchor(CaptureAnchor(sample: 0, ms: 1_800_000_001_000)), .device(sample: 0, device: builtIn)])
}

@Test func recorderKeepsWritingWhenTheInputFormatChanges() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .mic, now: { clock.now })

    recorder.open(directory: directory)
    feed(recorder, clock: clock, from: start, count: 10, sampleRate: 24_000, channels: 1)
    feed(recorder, clock: clock, from: start.addingTimeInterval(1), count: 10, sampleRate: 48_000, channels: 1)
    recorder.close()

    #expect(abs(sampleCount(directory, .mic) - 32_000) <= 4)
    #expect(recorder.snapshot().lastError == nil)
}

@Test func recorderReopensAPartlyWrittenRecordingAtSampleAndLineBoundaries() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pcmURL = CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: .system)
    let metaURL = CaptureSessionPaths.metaURL(sessionDirectory: directory, source: .system)
    try (CapturePCM.encode([0.1, 0.2]) + Data([0x01, 0x02])).write(to: pcmURL)
    let anchor = try CaptureMetaLine.anchor(CaptureAnchor(sample: 0, ms: 1_000)).encodedLine()
    try Data("\(anchor)\n{\"t\":\"anch".utf8).write(to: metaURL)

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .system, now: { clock.now })
    recorder.open(directory: directory)
    feed(recorder, clock: clock, from: start, count: 1)
    recorder.close()

    let samples = try CapturePCM.decode(Data(contentsOf: pcmURL))
    #expect(samples.prefix(2) == [0.1, 0.2])
    let lines = try String(contentsOf: metaURL, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(try CaptureMetaLine.decode(line: lines[2]) == .anchor(CaptureAnchor(sample: 2, ms: 1_800_000_000_000)))
}

@Test func recorderReportsStateAndOpenFailures() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let recorder = SourceRecorder(source: .system)

    recorder.open(directory: directory)
    recorder.noteState(.retrying, reason: "The stream was stopped by the system")
    #expect(recorder.snapshot().state == .retrying)
    #expect(recorder.snapshot().reason == "The stream was stopped by the system")
    recorder.noteState(.recording, reason: nil)
    #expect(recorder.snapshot().reason == nil)
    recorder.close()
    #expect(recorder.snapshot().state == .off)

    let blocked = directory.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    recorder.open(directory: blocked)
    #expect(recorder.snapshot().lastError?.hasPrefix("書き込み先を開けません") == true)
}

@Test func recorderForgetsTheLastErrorWhenOpeningAnotherRecording() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocked = directory.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    let recorder = SourceRecorder(source: .mic)

    recorder.open(directory: blocked)
    #expect(recorder.snapshot().lastError != nil)
    recorder.open(directory: directory.appendingPathComponent("next"))
    #expect(recorder.snapshot().lastError == nil)
}

@Test func recorderOpensAgainWhenTheDestinationBecomesWritable() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocked = directory.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .mic, now: { clock.now })

    recorder.open(directory: blocked)
    #expect(recorder.snapshot().lastError?.hasPrefix("書き込み先を開けません") == true)
    try FileManager.default.removeItem(at: blocked)

    feed(recorder, clock: clock, from: start, count: 3)
    #expect(sampleCount(blocked, .mic) == 0)
    feed(recorder, clock: clock, from: start.addingTimeInterval(2), count: 10)
    recorder.close()

    #expect(abs(sampleCount(blocked, .mic) - 16_000) <= 2)
    #expect(recorder.snapshot().lastError == nil)
}

@Test func recorderWritesEachStateOnlyOnce() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SourceRecorder(source: .system)

    recorder.open(directory: directory)
    for _ in 0..<5 {
        recorder.noteState(.retrying, reason: "接続できません")
    }
    recorder.noteState(.recording, reason: nil)
    recorder.noteState(.recording, reason: nil)
    recorder.close()

    let states = try metaLines(directory, .system).compactMap { line -> CaptureSourceState? in
        if case .state(_, _, let state, _) = line { state } else { nil }
    }
    #expect(states == [.retrying, .recording])
}

@Test func recorderShowsAnErrorTheCaptureReportedAndIgnoresEmptyBuffers() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SourceRecorder(source: .system)

    recorder.open(directory: directory)
    recorder.ingest(makeBuffer(sampleRate: 48_000, channels: 2, frames: 0))
    #expect(recorder.snapshot().lastError == nil)

    recorder.noteError("system音声のbufferを取り出せません")
    #expect(recorder.snapshot().lastError == "system音声のbufferを取り出せません")
}

@Test func recorderWritesAnchorsOnlyForSamplesInTheFile() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .mic, now: { clock.now })

    recorder.open(directory: directory)
    feed(recorder, clock: clock, from: start, count: 5)
    feed(recorder, clock: clock, from: start.addingTimeInterval(30), count: 5)
    recorder.close()

    let samples = sampleCount(directory, .mic)
    let anchors = try metaLines(directory, .mic).compactMap { line -> CaptureAnchor? in
        if case .anchor(let anchor) = line { anchor } else { nil }
    }
    #expect(anchors.count == 2)
    #expect(anchors.allSatisfy { $0.sample < samples })
}
