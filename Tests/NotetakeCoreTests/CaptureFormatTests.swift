import Foundation
import Testing
@testable import NotetakeCore

@Test func pcmConvertsBetweenSamplesAndMilliseconds() {
    #expect(CapturePCM.ms(forSamples: 16_000) == 1_000)
    #expect(CapturePCM.ms(forSamples: 8) == 1)
    #expect(CapturePCM.ms(forSamples: -16_000) == -1_000)
    #expect(CapturePCM.samples(forMS: 250) == 4_000)
}

@Test func pcmEncodesLittleEndianFloatsAndIgnoresPartialSample() {
    let data = CapturePCM.encode([0.5, -1])
    #expect(Array(data) == [0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x80, 0xBF])
    #expect(CapturePCM.decode(data + Data([0x01, 0x02])) == [0.5, -1])
}

@Test func metaLinesDecodeTheDocumentedExamples() throws {
    let anchor = try CaptureMetaLine.decode(line: #"{"t":"anchor","sample":0,"ms":1790999999000}"#)
    #expect(anchor == .anchor(CaptureAnchor(sample: 0, ms: 1_790_999_999_000)))

    let device = try CaptureMetaLine.decode(
        line: #"{"t":"device","sample":0,"device":{"name":"MacBook Proのマイク","uid":"BuiltInMicrophoneDevice","spatial":false}}"#)
    #expect(
        device
            == .device(
                sample: 0,
                device: InputDevice(name: "MacBook Proのマイク", uid: "BuiltInMicrophoneDevice", spatial: false)))

    let state = try CaptureMetaLine.decode(
        line: #"{"t":"state","sample":81920,"ms":1791000004120,"state":"retrying","reason":"The stream was stopped by the system"}"#)
    #expect(
        state
            == .state(
                sample: 81_920, ms: 1_791_000_004_120, state: .retrying,
                reason: "The stream was stopped by the system"))
}

@Test func metaLinesRoundTripAndRejectUnknownTypes() throws {
    let lines: [CaptureMetaLine] = [
        .anchor(CaptureAnchor(sample: 16_000, ms: 2_000)),
        .device(sample: 3, device: InputDevice(name: "外部マイク", uid: "external", spatial: false)),
        .state(sample: 5, ms: 6, state: .recording, reason: nil),
    ]
    for line in lines {
        #expect(try CaptureMetaLine.decode(line: try line.encodedLine()) == line)
    }
    #expect(try lines[0].encodedLine() == #"{"ms":2000,"sample":16000,"t":"anchor"}"#)
    #expect(throws: (any Error).self) {
        _ = try CaptureMetaLine.decode(line: #"{"t":"other","sample":0}"#)
    }
}

@Test func timelineAdvancesFromTheLastAnchor() {
    let timeline = CaptureTimeline(lines: [
        .anchor(CaptureAnchor(sample: 0, ms: 1_000_000)),
        .anchor(CaptureAnchor(sample: 32_000, ms: 1_600_000)),
    ])
    #expect(timeline.ms(atSample: 0) == 1_000_000)
    #expect(timeline.ms(atSample: 16_000) == 1_001_000)
    #expect(timeline.ms(atSample: 31_999) == 1_002_000)
    #expect(timeline.ms(atSample: 32_000) == 1_600_000)
    #expect(timeline.ms(atSample: 48_000) == 1_601_000)
}

@Test func timelineExtrapolatesBeforeTheFirstAnchorAndIsEmptyWithoutAnchors() {
    #expect(CaptureTimeline().ms(atSample: 0) == nil)
    let timeline = CaptureTimeline(lines: [.anchor(CaptureAnchor(sample: 16_000, ms: 10_000))])
    #expect(timeline.ms(atSample: 0) == 9_000)
}

@Test func timelineKeepsSampleOrderAndFindsTheDeviceInUse() {
    let builtIn = InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false)
    let headset = InputDevice(name: "ヘッドセット", uid: "headset", spatial: false)
    let timeline = CaptureTimeline(lines: [
        .device(sample: 0, device: builtIn),
        .anchor(CaptureAnchor(sample: 16_000, ms: 50_000)),
        .state(sample: 8_000, ms: 1, state: .retrying, reason: "停止"),
        .anchor(CaptureAnchor(sample: 0, ms: 10_000)),
        .device(sample: 16_000, device: headset),
    ])
    #expect(timeline.anchors.map(\.sample) == [0, 16_000])
    #expect(timeline.ms(atSample: 8_000) == 10_500)
    #expect(timeline.device(atSample: 15_999) == builtIn)
    #expect(timeline.device(atSample: 16_000) == headset)
}

@Test func anchorClockAnchorsTheFirstBufferAndGapsBeyondTolerance() {
    var clock = AnchorClock()
    #expect(clock.anchor(forBufferStartingAt: 0, wallClockMS: 1_000) == CaptureAnchor(sample: 0, ms: 1_000))
    #expect(clock.anchor(forBufferStartingAt: 16_000, wallClockMS: 2_000) == nil)
    #expect(clock.anchor(forBufferStartingAt: 32_000, wallClockMS: 3_250) == nil)
    #expect(clock.anchor(forBufferStartingAt: 32_000, wallClockMS: 2_749) == CaptureAnchor(sample: 32_000, ms: 2_749))
    #expect(clock.anchor(forBufferStartingAt: 48_000, wallClockMS: 63_749) == CaptureAnchor(sample: 48_000, ms: 63_749))
}

@Test func anchorClockAnchorsAgainAfterReset() {
    var clock = AnchorClock()
    _ = clock.anchor(forBufferStartingAt: 0, wallClockMS: 1_000)
    clock.reset()
    #expect(clock.anchor(forBufferStartingAt: 0, wallClockMS: 1_000) == CaptureAnchor(sample: 0, ms: 1_000))
}

@Test func sessionInfoUsesSnakeCaseKeysAndRawAudioPaths() throws {
    let info = CaptureSessionInfo(
        outputDirectory: "/Users/example/Downloads", device: "mac-1", deviceName: "山田のMac", owner: "山田太郎")
    let text = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
    #expect(text.contains("\"output_directory\""))
    #expect(text.contains("\"device_name\""))
    #expect(try JSONDecoder().decode(CaptureSessionInfo.self, from: Data(text.utf8)) == info)

    let directory = URL(fileURLWithPath: "/tmp/notetake-capture/2026-10-03_100000")
    #expect(CaptureSessionPaths.sessionInfoURL(sessionDirectory: directory).lastPathComponent == "session.json")
    #expect(CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: .mic).lastPathComponent == "mic.pcm")
    #expect(
        CaptureSessionPaths.metaURL(sessionDirectory: directory, source: .system).lastPathComponent
            == "system.meta.jsonl")
}
