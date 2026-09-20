import AVFoundation
import Foundation
import struct NotetakeCore.RawAudioFrame
import XCTest

@testable import notetaked

/// captureコールバックが受け取ったbufferを、任意のスレッドから安全に集める。
/// `RawAudioReaderCapture`のpoll taskは順次実行だが、`@Sendable`境界を跨ぐため
/// NSLockで保護する
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        buffers.append(buffer)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    var all: [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }
}

@available(macOS 26, iOS 26, *)
final class RawAudioReaderCaptureTests: XCTestCase {
    private func makeFrame(sampleRate: Double, channelCount: Int, sampleCount: Int, startValue: Float) -> RawAudioFrame {
        RawAudioFrame(
            sampleRate: sampleRate, channelCount: channelCount,
            samples: (0..<sampleCount).map { startValue + Float($0) })
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// AirPods切断→OS既定フォールバックのような、途中でsampleRate/channelCountが変わる
    /// frame列を与えた時、変化後のframeがdropされず正しく処理され続けることを検証する（issue #18）
    func testFormatChangeMidStreamIsNotDropped() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".raw")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let firstSegment = (0..<3).map { makeFrame(sampleRate: 24000, channelCount: 1, sampleCount: 160, startValue: Float($0)) }
        let handle = try FileHandle(forWritingTo: tempURL)
        for frame in firstSegment {
            handle.write(frame.encoded())
        }

        let capture = try await RawAudioReaderCapture(fileURL: tempURL, startOffset: 0)
        XCTAssertEqual(capture.format.sampleRate, 24000)
        XCTAssertEqual(capture.format.channelCount, 1)

        let collector = BufferCollector()
        try capture.start { buffer in
            collector.append(buffer)
        }

        await waitUntil { collector.count >= firstSegment.count }
        XCTAssertEqual(collector.count, firstSegment.count)

        // pinしたデバイスの切断→OS既定フォールバックを模して、sampleRate/channelCountの
        // 異なるframeを追記する
        let secondSegment = (0..<3).map { makeFrame(sampleRate: 48000, channelCount: 1, sampleCount: 320, startValue: Float(100 + $0)) }
        for frame in secondSegment {
            handle.write(frame.encoded())
        }
        try? handle.close()

        await waitUntil { collector.count >= firstSegment.count + secondSegment.count }
        capture.stop()

        let received = collector.all
        XCTAssertEqual(
            received.count, firstSegment.count + secondSegment.count,
            "format変化後のframeがdropされず全て配信されること")

        let afterChange = received.suffix(secondSegment.count)
        for buffer in afterChange {
            XCTAssertEqual(buffer.format.sampleRate, 48000)
            XCTAssertEqual(buffer.frameLength, 320)
        }
        XCTAssertEqual(afterChange.first?.floatChannelData?[0][0], 100)

        // formatがそれ以降の新しいsampleRateへ追従していること
        XCTAssertEqual(capture.format.sampleRate, 48000)
        XCTAssertEqual(capture.format.channelCount, 1)
    }

    /// sampleRateが変わっても、audio時間軸ベースのcheckpoint（offset(atOrBeforeAudioMS:)）が
    /// 壊れず単調に前進し続けることを検証する（issue #18の根本原因の副作用）
    func testCheckpointOffsetAdvancesAcrossFormatChange() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".raw")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let firstSegment = (0..<3).map { makeFrame(sampleRate: 24000, channelCount: 1, sampleCount: 2400, startValue: Float($0)) }
        let handle = try FileHandle(forWritingTo: tempURL)
        for frame in firstSegment {
            handle.write(frame.encoded())
        }

        let capture = try await RawAudioReaderCapture(fileURL: tempURL, startOffset: 0)
        let collector = BufferCollector()
        try capture.start { buffer in
            collector.append(buffer)
        }
        await waitUntil { collector.count >= firstSegment.count }

        let offsetBeforeChange = capture.currentOffset
        XCTAssertGreaterThan(offsetBeforeChange, 0)

        let secondSegment = (0..<3).map { makeFrame(sampleRate: 48000, channelCount: 1, sampleCount: 4800, startValue: Float(100 + $0)) }
        for frame in secondSegment {
            handle.write(frame.encoded())
        }
        try? handle.close()
        await waitUntil { collector.count >= firstSegment.count + secondSegment.count }
        capture.stop()

        let finalOffset = capture.currentOffset
        XCTAssertGreaterThan(finalOffset, offsetBeforeChange)

        // targetMS=0はログ上最も古いoffsetへ、大きなtargetMSは最新offsetへ丸められる
        XCTAssertLessThanOrEqual(capture.offset(atOrBeforeAudioMS: 0), offsetBeforeChange)
        XCTAssertEqual(capture.offset(atOrBeforeAudioMS: .max), finalOffset)
    }
}
