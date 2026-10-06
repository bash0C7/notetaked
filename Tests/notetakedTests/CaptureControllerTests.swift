import AVFoundation
import Foundation
import NotetakeCore
import Testing
@testable import notetaked

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

private func monoBuffer(frames: Int) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
}

private func sampleCount(_ directory: URL, _ source: Source) -> Int64 {
    let url = CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: source)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    return (size?.int64Value ?? 0) / Int64(CapturePCM.bytesPerSample)
}

/// 呼ばれた開始と停止を数えるだけの取り込み
private final class FakeCapture: SourceCapture, @unchecked Sendable {
    let source: Source
    let pinnedInputUID: String?
    private let lock = NSLock()
    private var sinkValue: (any CaptureSink)?
    private var stopCount = 0

    init(source: Source, pinnedInputUID: String?) {
        self.source = source
        self.pinnedInputUID = pinnedInputUID
    }

    var sink: (any CaptureSink)? { lock.withLock { sinkValue } }
    var stops: Int { lock.withLock { stopCount } }

    func start(into sink: any CaptureSink) async {
        lock.withLock { sinkValue = sink }
        sink.noteState(.recording, reason: nil)
    }

    func stop() async {
        lock.withLock { stopCount += 1 }
    }
}

private final class FakeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeCapture] = []

    var captures: [FakeCapture] { lock.withLock { made } }

    func make(_ source: Source, _ pinnedInputUID: String?) -> any SourceCapture {
        let capture = FakeCapture(source: source, pinnedInputUID: pinnedInputUID)
        lock.withLock { made.append(capture) }
        return capture
    }
}

private func desired(_ prefix: String?, root: URL, sources: [Source] = [.mic, .system], pin: String? = nil) -> CaptureDesiredState {
    CaptureDesiredState(
        recording: prefix.map { .init(prefix: $0, directory: root.appendingPathComponent($0).path) },
        sources: sources, pinnedInputUID: pin)
}

@Test func controllerStartsSourcesAndSwitchesDirectoriesWithoutRestarting() async throws {
    let root = temporaryDirectory("controller")
    defer { try? FileManager.default.removeItem(at: root) }
    let factory = FakeFactory()
    let controller = CaptureController(makeCapture: { factory.make($0, $1) })

    await controller.apply(desired("a", root: root))
    #expect(factory.captures.map(\.source) == [.mic, .system])

    await controller.apply(desired("b", root: root))
    #expect(factory.captures.count == 2)
    factory.captures[0].sink?.ingest(monoBuffer(frames: 1_600))
    let state = await controller.actualState(pid: 7, now: Date(timeIntervalSince1970: 1))
    #expect(state.prefix == "b")
    #expect(state.sources.map(\.state) == [.recording, .recording])
    #expect(sampleCount(root.appendingPathComponent("b"), .mic) == 1_600)
    #expect(sampleCount(root.appendingPathComponent("a"), .mic) == 0)
}

@Test func controllerRestartsOnlyTheMicWhenThePinChanges() async throws {
    let root = temporaryDirectory("controller")
    defer { try? FileManager.default.removeItem(at: root) }
    let factory = FakeFactory()
    let controller = CaptureController(makeCapture: { factory.make($0, $1) })

    await controller.apply(desired("a", root: root))
    await controller.apply(desired("a", root: root, pin: "headset"))

    #expect(factory.captures.map(\.source) == [.mic, .system, .mic])
    #expect(factory.captures[0].stops == 1)
    #expect(factory.captures[1].stops == 0)
    #expect(factory.captures[2].pinnedInputUID == "headset")
}

@Test func controllerStopsEverythingWhenRecordingEnds() async throws {
    let root = temporaryDirectory("controller")
    defer { try? FileManager.default.removeItem(at: root) }
    let factory = FakeFactory()
    let controller = CaptureController(makeCapture: { factory.make($0, $1) })

    await controller.apply(desired("a", root: root))
    await controller.apply(.stopped)

    #expect(factory.captures.map(\.stops) == [1, 1])
    let state = await controller.actualState(pid: 7, now: Date())
    #expect(state.prefix == nil)
    #expect(state.sources.isEmpty)
}
