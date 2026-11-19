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

/// 書き込みや変換の失敗を、テストの好きな時点で起こす
private final class Fault: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func set(_ value: Bool) { lock.withLock { active = value } }

    func check() throws {
        if lock.withLock({ active }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }
}

@Test func recorderIgnoresEmptyBuffers() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = SourceRecorder(source: .system)

    recorder.open(directory: directory)
    recorder.ingest(makeBuffer(sampleRate: 48_000, channels: 2, frames: 0))
    #expect(recorder.snapshot().lastError == nil)
    #expect(recorder.snapshot().noticeAtMS == nil)
}

@Test func recorderKeepsTheCaptureNoticeOutOfTheLastErrorAndStampsIt() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .system, now: { clock.now })
    recorder.open(directory: directory)

    recorder.noteError("system音声のbufferを取り出せません")
    var status = recorder.snapshot()
    #expect(status.lastError == nil)
    #expect(status.notice == "system音声のbufferを取り出せません")
    #expect(status.noticeAtMS == 1_800_000_000_000)

    clock.set(start.addingTimeInterval(1))
    recorder.noteError("入力機器の音声を取り込めません")
    status = recorder.snapshot()
    #expect(status.lastError == nil)
    #expect(status.notice == "入力機器の音声を取り込めません")
    #expect(status.noticeAtMS == 1_800_000_001_000)
}

@Test func recorderCountsARepeatedNoticeAgainOnlyAfterTheTransientHasPassed() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let recorder = SourceRecorder(source: .system, now: { clock.now })
    recorder.open(directory: directory)

    recorder.noteError("system音声のbufferを取り出せません")
    // callbackのたびに失敗する時、appに10秒の一時表示を毎秒積まない
    clock.set(start.addingTimeInterval(5))
    recorder.noteError("system音声のbufferを取り出せません")
    // 数えない繰り返しは、通知の時刻も進めない
    #expect(recorder.snapshot().noticeAtMS == 1_800_000_000_000)

    clock.set(start.addingTimeInterval(11))
    recorder.noteError("system音声のbufferを取り出せません")
    #expect(recorder.snapshot().noticeAtMS == 1_800_000_011_000)
}

@Test func recorderForgetsThePcmErrorOnlyWhenItWritesAudioAgain() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let pcmFault = Fault()
    let recorder = SourceRecorder(
        source: .system, now: { clock.now }, faults: .init(pcmWrite: { try pcmFault.check() }))
    recorder.open(directory: directory)

    pcmFault.set(true)
    feed(recorder, clock: clock, from: start, count: 3)
    #expect(recorder.snapshot().lastError?.hasPrefix("生音声を書けません") == true)
    #expect(recorder.snapshot().noticeAtMS == nil)

    pcmFault.set(false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.3), count: 3)
    #expect(recorder.snapshot().lastError == nil)
    recorder.close()
}

@Test func recorderKeepsTheMetaErrorWhenAPcmWriteSucceeds() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let metaFault = Fault()
    let recorder = SourceRecorder(
        source: .mic, now: { clock.now }, faults: .init(metaWrite: { try metaFault.check() }))
    let builtIn = InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false)
    recorder.open(directory: directory)

    metaFault.set(true)
    feed(recorder, clock: clock, from: start, count: 3)
    #expect(recorder.snapshot().lastError?.hasPrefix("時刻情報を書けません") == true)

    // 音声は書けても、時刻情報が書けない状態は治っていない
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.3), count: 3)
    #expect(recorder.snapshot().lastError?.hasPrefix("時刻情報を書けません") == true)

    // 時刻情報の行を書く機会が来て、書けたら消える
    metaFault.set(false)
    recorder.noteInput(builtIn, fellBackFromPinned: false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.6), count: 3)
    #expect(recorder.snapshot().lastError == nil)
    recorder.close()
}

@Test func recorderRetriesTheAnchorAfterAFailedMetaWriteSoTheErrorClears() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let metaFault = Fault()
    let recorder = SourceRecorder(
        source: .mic, now: { clock.now }, faults: .init(metaWrite: { try metaFault.check() }))
    recorder.open(directory: directory)

    // 1度失敗しただけでも、anchorが書かれないまま次のbufferへ進むと、書く機会が来ず失敗が残り続ける
    metaFault.set(true)
    feed(recorder, clock: clock, from: start, count: 3)
    #expect(recorder.snapshot().lastError?.hasPrefix("時刻情報を書けません") == true)

    metaFault.set(false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.3), count: 1)
    #expect(recorder.snapshot().lastError == nil)
    recorder.close()

    let anchors = try metaLines(directory, .mic).compactMap { line -> CaptureAnchor? in
        if case .anchor(let anchor) = line { anchor } else { nil }
    }
    #expect(anchors.count == 1)
}

@Test func recorderForgetsTheConvertErrorOnlyWhenItConvertsAgain() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let convertFault = Fault()
    let recorder = SourceRecorder(
        source: .mic, now: { clock.now }, faults: .init(convert: { try convertFault.check() }))
    recorder.open(directory: directory)

    convertFault.set(true)
    feed(recorder, clock: clock, from: start, count: 3)
    #expect(recorder.snapshot().lastError?.hasPrefix("16kHzへ変換できません") == true)

    convertFault.set(false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.3), count: 3)
    #expect(recorder.snapshot().lastError == nil)
    recorder.close()
}

@Test func recorderTracksEachPersistentFailureSeparatelyAndShowsOneDeterministically() throws {
    let directory = temporaryDirectory("recorder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = TestClock(start)
    let metaFault = Fault()
    let convertFault = Fault()
    let pcmFault = Fault()
    let recorder = SourceRecorder(
        source: .mic, now: { clock.now },
        faults: .init(
            pcmWrite: { try pcmFault.check() }, metaWrite: { try metaFault.check() },
            convert: { try convertFault.check() }))
    recorder.open(directory: directory)

    let builtIn = InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false)
    // 変換器は最初のbufferでは音を出さないので、先に1つ流しておく
    feed(recorder, clock: clock, from: start, count: 2)

    metaFault.set(true)
    recorder.noteInput(builtIn, fellBackFromPinned: false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.2), count: 1)
    convertFault.set(true)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.3), count: 1)
    // 時刻情報と変換が同時に続く間は、時刻情報（meta > convert）を示す
    #expect(recorder.snapshot().lastError?.hasPrefix("時刻情報を書けません") == true)

    pcmFault.set(true)
    convertFault.set(false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.4), count: 1)
    // 変換が治っても、時刻情報は残る。音声の書き込みの失敗が加わると、そちらが優先される
    #expect(recorder.snapshot().lastError?.hasPrefix("生音声を書けません") == true)

    // 音声の書き込みが治っても、時刻情報の失敗は消えない
    pcmFault.set(false)
    feed(recorder, clock: clock, from: start.addingTimeInterval(0.5), count: 1)
    #expect(recorder.snapshot().lastError?.hasPrefix("時刻情報を書けません") == true)
    recorder.close()
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
