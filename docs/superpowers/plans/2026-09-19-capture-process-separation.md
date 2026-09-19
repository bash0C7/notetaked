# Capture Process Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 音声取り込み（マイク/システム音声のtap）を`notetaked serve`（既存プロセス、以後「process」）から新設の`notetaked capture-daemon`（以後「capture」）へ分離し、processがハング/クラッシュしても音声取り込みが止まらず、再起動後もバッファ済み音声から再開できるようにする。

**Architecture:** `capture`はマイク/システム音声を`AudioCapture`実装（既存の`MicCapture`/`SystemAudioCapture`）で受け取り、OS tmp領域へ自己記述フレーム形式で追記し続ける軽量常駐プロセス。`process`は`capture`が書いたファイルを`RawAudioReaderCapture`（既存`AudioCapture`プロトコル準拠の新実装）でtail読みし、既存の`CaptureStream`以降のロジック（話者分離・文字起こし・出力・制御）はそのまま使う。両プロセス間の制御（セッション開始/終了・機材フォールバック通知）は、Unix socket等の新規IPCではなく、**既にこのplanで作る`CaptureCheckpoint`と同じ「アトミックファイル書き込み＋ポーリング」パターンを使い回す**`CaptureControlChannel`で行う（新規IPCプリミティブを増やさずリスクを下げる判断）。メニューバーapp（Notetake.app）は両プロセスを個別に起動し、固定パスのheartbeatファイルのmtimeで生存監視、閾値超過でgraceful→forced再起動する。

**Tech Stack:** Swift 6 / SwiftPM（`NotetakeCore`ライブラリ・`notetaked`executable）、AVFoundation（`AVAudioPCMBuffer`/`AVAudioFormat`）、Foundation（`FileHandle`/`FileManager`、`Process`）、Swift Testing（`@Test`/`#expect`）、既存`ArgumentParser`ベースのsubcommand構成。

**Spec:** `docs/superpowers/specs/2026-09-19-capture-process-separation-design.md`

## Global Constraints

- tmpの生音声バッファは「録音」ではなく「バッファリング」という既存方針を維持する。ローテーション・切り詰めロジックは実装しない。削除はOSのtmp管理に任せる
- 心拍ファイルは新規の構造化ログ/イベントを増やさない。ファイルへのタイムスタンプ上書きのみ
- heartbeat間隔は5秒、ハング判定閾値は15秒（心拍間隔の3倍）
- 復旧はgraceful（`process`には`quit`コマンド、`capture`には`SIGTERM`、共に5秒猶予）→forced（`SIGKILL`）の順
- `capture`自体のクラッシュ中の音声消失は許容する（復旧不可能、仕様上の非ゴール）
- 既存の`MicCapture`/`SystemAudioCapture`/`CaptureStream`/`AudioConverter`のフォーマット変化に関する挙動は変更しない。バッファの運び方（直接closure呼び出し→ファイル経由tail読み）だけを変える
- 日本語と英数字の間に空白を入れない（コード内コメント・doc・commit message本文）
- commit messageの末尾にCo-Authored-By / Claude-Session trailerを付ける

---

## Task 1: RawAudioFrame（自己記述フレームのencode/decode）

**Files:**
- Create: `Sources/NotetakeCore/Capture/RawAudioFrame.swift`
- Test: `Tests/NotetakeCoreTests/RawAudioFrameTests.swift`

**Interfaces:**
- Produces: `RawAudioFrame`（`sampleRate: Double`, `channelCount: Int`, `samples: [Float]`）、`encoded() -> Data`、`static decode(from:at:) -> (frame: RawAudioFrame, nextOffset: Int)?`

バイナリレイアウト（1フレーム）: `[8 bytes sampleRate(Double bitPattern, little endian)][4 bytes channelCount(UInt32 LE)][4 bytes sampleCount(UInt32 LE) = samples.count][sampleCount * 4 bytes Float32 LE]`。`decode`はバッファ不足（部分フレーム）なら`nil`を返す。

- [ ] **Step 1: 失敗するテストを書く**

```swift
// Tests/NotetakeCoreTests/RawAudioFrameTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func encodeDecodeRoundTrip() {
    let frame = RawAudioFrame(sampleRate: 48000, channelCount: 1, samples: [0.1, -0.2, 0.3, 0.0])
    let data = frame.encoded()
    let decoded = RawAudioFrame.decode(from: data, at: 0)
    #expect(decoded != nil)
    #expect(decoded?.frame == frame)
    #expect(decoded?.nextOffset == data.count)
}

@Test func decodeReturnsNilOnPartialFrame() {
    let frame = RawAudioFrame(sampleRate: 16000, channelCount: 2, samples: [1, 2, 3, 4])
    let full = frame.encoded()
    let partial = full.prefix(full.count - 1)
    #expect(RawAudioFrame.decode(from: Data(partial), at: 0) == nil)
}

@Test func decodeReturnsNilWhenLessThanHeaderSize() {
    #expect(RawAudioFrame.decode(from: Data([0, 1, 2]), at: 0) == nil)
}

@Test func multipleFramesConcatenateAndDecodeSequentially() {
    let a = RawAudioFrame(sampleRate: 48000, channelCount: 1, samples: [1, 2])
    let b = RawAudioFrame(sampleRate: 48000, channelCount: 1, samples: [3, 4, 5])
    var combined = a.encoded()
    combined.append(b.encoded())
    let (firstFrame, offsetAfterFirst) = RawAudioFrame.decode(from: combined, at: 0)!
    #expect(firstFrame == a)
    let (secondFrame, offsetAfterSecond) = RawAudioFrame.decode(from: combined, at: offsetAfterFirst)!
    #expect(secondFrame == b)
    #expect(offsetAfterSecond == combined.count)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter RawAudioFrameTests`
Expected: FAIL（`RawAudioFrame`が存在しない）

- [ ] **Step 3: 最小実装を書く**

```swift
// Sources/NotetakeCore/Capture/RawAudioFrame.swift
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
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter RawAudioFrameTests`
Expected: PASS（4件）

- [ ] **Step 5: commit**

```bash
git add Sources/NotetakeCore/Capture/RawAudioFrame.swift Tests/NotetakeCoreTests/RawAudioFrameTests.swift
git commit -m "$(cat <<'EOF'
feat(capture): add self-describing raw audio frame encoding

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 2: CaptureSessionPaths + CaptureCheckpoint

**Files:**
- Create: `Sources/NotetakeCore/Capture/CaptureSessionPaths.swift`
- Create: `Sources/NotetakeCore/Capture/CaptureCheckpoint.swift`
- Test: `Tests/NotetakeCoreTests/CaptureCheckpointTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `CaptureSessionPaths.sessionDirectory(prefix:baseTemporaryDirectory:) -> URL`、`.rawFileURL(sessionDirectory:source:) -> URL`、`.checkpointFileURL(sessionDirectory:source:) -> URL`。`CaptureCheckpoint`（`offsets: [String: Int]`）、`.load(from:) -> CaptureCheckpoint`、`.save(to:) throws`

- [ ] **Step 1: 失敗するテストを書く**

```swift
// Tests/NotetakeCoreTests/CaptureCheckpointTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func sessionDirectoryIsUnderCaptureNamespace() {
    let base = URL(fileURLWithPath: "/tmp")
    let dir = CaptureSessionPaths.sessionDirectory(prefix: "2026-09-19_120000", baseTemporaryDirectory: base)
    #expect(dir.path == "/tmp/notetake-capture/2026-09-19_120000")
}

@Test func rawAndCheckpointFileURLsAreDistinctPerSource() {
    let dir = URL(fileURLWithPath: "/tmp/notetake-capture/session")
    #expect(CaptureSessionPaths.rawFileURL(sessionDirectory: dir, source: "mic").lastPathComponent == "mic.raw")
    #expect(CaptureSessionPaths.checkpointFileURL(sessionDirectory: dir, source: "mic").lastPathComponent == "mic.checkpoint")
    #expect(CaptureSessionPaths.rawFileURL(sessionDirectory: dir, source: "system").lastPathComponent == "system.raw")
}

@Test func loadReturnsEmptyWhenFileMissing() {
    let missing = URL(fileURLWithPath: "/tmp/notetake-capture-tests-\(UUID().uuidString)/none.checkpoint")
    #expect(CaptureCheckpoint.load(from: missing) == CaptureCheckpoint())
}

@Test func saveThenLoadRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("mic.checkpoint")
    let checkpoint = CaptureCheckpoint(offsets: ["mic": 4096])
    try checkpoint.save(to: fileURL)
    #expect(CaptureCheckpoint.load(from: fileURL) == checkpoint)
}

@Test func saveOverwritesAtomically() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("mic.checkpoint")
    try CaptureCheckpoint(offsets: ["mic": 100]).save(to: fileURL)
    try CaptureCheckpoint(offsets: ["mic": 200]).save(to: fileURL)
    #expect(CaptureCheckpoint.load(from: fileURL).offsets["mic"] == 200)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(leftovers == ["mic.checkpoint"])
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter CaptureCheckpointTests`
Expected: FAIL（型が存在しない）

- [ ] **Step 3: 最小実装を書く**

```swift
// Sources/NotetakeCore/Capture/CaptureSessionPaths.swift
import Foundation

public enum CaptureSessionPaths {
    public static func sessionDirectory(
        prefix: String,
        baseTemporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) -> URL {
        baseTemporaryDirectory.appendingPathComponent("notetake-capture").appendingPathComponent(prefix)
    }

    public static func rawFileURL(sessionDirectory: URL, source: String) -> URL {
        sessionDirectory.appendingPathComponent("\(source).raw")
    }

    public static func checkpointFileURL(sessionDirectory: URL, source: String) -> URL {
        sessionDirectory.appendingPathComponent("\(source).checkpoint")
    }
}
```

```swift
// Sources/NotetakeCore/Capture/CaptureCheckpoint.swift
import Foundation

public struct CaptureCheckpoint: Codable, Equatable, Sendable {
    public var offsets: [String: Int]

    public init(offsets: [String: Int] = [:]) {
        self.offsets = offsets
    }

    public static func load(from url: URL) -> CaptureCheckpoint {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CaptureCheckpoint.self, from: data) else {
            return CaptureCheckpoint()
        }
        return decoded
    }

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter CaptureCheckpointTests`
Expected: PASS（5件）

- [ ] **Step 5: commit**

```bash
git add Sources/NotetakeCore/Capture/CaptureSessionPaths.swift Sources/NotetakeCore/Capture/CaptureCheckpoint.swift Tests/NotetakeCoreTests/CaptureCheckpointTests.swift
git commit -m "$(cat <<'EOF'
feat(capture): add session path helpers and atomic checkpoint persistence

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 3: Heartbeat + CaptureStatePaths

**Files:**
- Create: `Sources/NotetakeCore/Capture/Heartbeat.swift`
- Create: `Sources/NotetakeCore/Capture/CaptureStatePaths.swift`
- Test: `Tests/NotetakeCoreTests/HeartbeatTests.swift`

**Interfaces:**
- Produces: `HeartbeatStatus`（`.alive`/`.stale`）、`Heartbeat.write(to:now:) throws`、`Heartbeat.status(lastBeat:now:threshold:) -> HeartbeatStatus`、`Heartbeat.currentStatus(of:now:threshold:) -> HeartbeatStatus`。`CaptureStatePaths.stateDirectory() -> URL`、`.processHeartbeatURL`、`.captureHeartbeatURL`、`.captureCommandURL`、`.captureEventURL`、`.currentSessionMarkerURL`（いずれも`URL`）

- [ ] **Step 1: 失敗するテストを書く**

```swift
// Tests/NotetakeCoreTests/HeartbeatTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func statusIsAliveWithinThreshold() {
    let now = Date()
    let lastBeat = now.addingTimeInterval(-10)
    #expect(Heartbeat.status(lastBeat: lastBeat, now: now, threshold: 15) == .alive)
}

@Test func statusIsStaleBeyondThreshold() {
    let now = Date()
    let lastBeat = now.addingTimeInterval(-16)
    #expect(Heartbeat.status(lastBeat: lastBeat, now: now, threshold: 15) == .stale)
}

@Test func statusIsStaleWhenNoBeatRecorded() {
    #expect(Heartbeat.status(lastBeat: nil, now: Date(), threshold: 15) == .stale)
}

@Test func writeThenCurrentStatusIsAlive() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heartbeat-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("process.heartbeat")
    try Heartbeat.write(to: url)
    #expect(Heartbeat.currentStatus(of: url, threshold: 15) == .alive)
}

@Test func currentStatusIsStaleWhenFileMissing() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).heartbeat")
    #expect(Heartbeat.currentStatus(of: missing, threshold: 15) == .stale)
}

@Test func statePathsAreDistinct() {
    let paths = [
        CaptureStatePaths.processHeartbeatURL,
        CaptureStatePaths.captureHeartbeatURL,
        CaptureStatePaths.captureCommandURL,
        CaptureStatePaths.captureEventURL,
        CaptureStatePaths.currentSessionMarkerURL,
    ]
    #expect(Set(paths.map(\.lastPathComponent)).count == paths.count)
    #expect(CaptureStatePaths.processHeartbeatURL.path.contains("Notetake/state"))
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter HeartbeatTests`
Expected: FAIL

- [ ] **Step 3: 最小実装を書く**

```swift
// Sources/NotetakeCore/Capture/Heartbeat.swift
import Foundation

public enum HeartbeatStatus: Equatable, Sendable {
    case alive
    case stale
}

public enum Heartbeat {
    public static func write(to url: URL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = ISO8601DateFormatter().string(from: now).data(using: .utf8) ?? Data()
        let tempURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try payload.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    public static func status(lastBeat: Date?, now: Date, threshold: TimeInterval) -> HeartbeatStatus {
        guard let lastBeat else { return .stale }
        return now.timeIntervalSince(lastBeat) > threshold ? .stale : .alive
    }

    public static func currentStatus(of url: URL, now: Date = Date(), threshold: TimeInterval) -> HeartbeatStatus {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return .stale
        }
        return status(lastBeat: modified, now: now, threshold: threshold)
    }
}
```

```swift
// Sources/NotetakeCore/Capture/CaptureStatePaths.swift
import Foundation

public enum CaptureStatePaths {
    public static func stateDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notetake").appendingPathComponent("state")
    }

    public static var processHeartbeatURL: URL { stateDirectory().appendingPathComponent("process.heartbeat") }
    public static var captureHeartbeatURL: URL { stateDirectory().appendingPathComponent("capture.heartbeat") }
    public static var captureCommandURL: URL { stateDirectory().appendingPathComponent("capture-command.json") }
    public static var captureEventURL: URL { stateDirectory().appendingPathComponent("capture-event.json") }
    public static var currentSessionMarkerURL: URL { stateDirectory().appendingPathComponent("current-session.json") }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter HeartbeatTests`
Expected: PASS（6件）

- [ ] **Step 5: commit**

```bash
git add Sources/NotetakeCore/Capture/Heartbeat.swift Sources/NotetakeCore/Capture/CaptureStatePaths.swift Tests/NotetakeCoreTests/HeartbeatTests.swift
git commit -m "$(cat <<'EOF'
feat(capture): add heartbeat status logic and fixed state file paths

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 4: CaptureCommand / CaptureEvent

**Files:**
- Create: `Sources/NotetakeCore/Control/CaptureCommand.swift`
- Test: `Tests/NotetakeCoreTests/CaptureCommandTests.swift`

**Interfaces:**
- Produces: `CaptureCommand`（`.startSession(directory: String, sources: [String], inputDeviceUID: String?)` / `.stopSession` / `.quit`）、`CaptureEvent`（`.started(directory: String)` / `.stopped` / `.inputFallback` / `.error(String)`）。両方 `Codable, Equatable, Sendable`

既存`Messages.swift`と違い、これらは1接続の行ストリームではなく単発のJSONファイルに書く用途のため、`encodedLine()`のような行形式は不要。素の`Codable`のみ。

- [ ] **Step 1: 失敗するテストを書く**

```swift
// Tests/NotetakeCoreTests/CaptureCommandTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func captureCommandStartSessionRoundTrips() throws {
    let command = CaptureCommand.startSession(directory: "/tmp/x", sources: ["mic", "system"], inputDeviceUID: "abc")
    let data = try JSONEncoder().encode(command)
    let decoded = try JSONDecoder().decode(CaptureCommand.self, from: data)
    #expect(decoded == command)
}

@Test func captureCommandStopSessionAndQuitRoundTrip() throws {
    for command: CaptureCommand in [.stopSession, .quit] {
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(CaptureCommand.self, from: data) == command)
    }
}

@Test func captureEventAllCasesRoundTrip() throws {
    let events: [CaptureEvent] = [.started(directory: "/tmp/x"), .stopped, .inputFallback, .error("boom")]
    for event in events {
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(CaptureEvent.self, from: data) == event)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter CaptureCommandTests`
Expected: FAIL

- [ ] **Step 3: 最小実装を書く**

```swift
// Sources/NotetakeCore/Control/CaptureCommand.swift
import Foundation

public enum CaptureCommand: Codable, Equatable, Sendable {
    case startSession(directory: String, sources: [String], inputDeviceUID: String?)
    case stopSession
    case quit
}

public enum CaptureEvent: Codable, Equatable, Sendable {
    case started(directory: String)
    case stopped
    case inputFallback
    case error(String)
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter CaptureCommandTests`
Expected: PASS（3件）

- [ ] **Step 5: commit**

```bash
git add Sources/NotetakeCore/Control/CaptureCommand.swift Tests/NotetakeCoreTests/CaptureCommandTests.swift
git commit -m "$(cat <<'EOF'
feat(capture): add capture<->process control message types

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 5: CaptureControlChannel（ファイルベースの単発メッセージ交換）

**Files:**
- Create: `Sources/NotetakeCore/Capture/CaptureControlChannel.swift`
- Test: `Tests/NotetakeCoreTests/CaptureControlChannelTests.swift`

**Interfaces:**
- Consumes: 任意の`Codable & Equatable & Sendable`型（`CaptureCommand`/`CaptureEvent`をこのタスクの後で使う）
- Produces: `CaptureControlChannel<Message>`（`fileURL: URL`）、`send(_:) throws`、`poll(after: Date?) -> (message: Message, sentAt: Date)?`

- [ ] **Step 1: 失敗するテストを書く**

```swift
// Tests/NotetakeCoreTests/CaptureControlChannelTests.swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func pollReturnsNilWhenNothingSent() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    #expect(channel.poll(after: nil) == nil)
}

@Test func sendThenPollReturnsMessage() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    try channel.send(.stopSession)
    let result = channel.poll(after: nil)
    #expect(result?.message == .stopSession)
}

@Test func pollWithAfterSkipsAlreadySeenMessage() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    try channel.send(.stopSession)
    let first = channel.poll(after: nil)!
    #expect(channel.poll(after: first.sentAt) == nil)
}

@Test func secondSendIsVisibleAfterFirstIsSeen() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
    let channel = CaptureControlChannel<CaptureCommand>(fileURL: url)
    try channel.send(.stopSession)
    let first = channel.poll(after: nil)!
    try channel.send(.quit)
    let second = channel.poll(after: first.sentAt)
    #expect(second?.message == .quit)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter CaptureControlChannelTests`
Expected: FAIL

- [ ] **Step 3: 最小実装を書く**

```swift
// Sources/NotetakeCore/Capture/CaptureControlChannel.swift
import Foundation

public struct CaptureControlChannel<Message: Codable & Equatable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func send(_ message: Message) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let envelope = Envelope(sentAt: Date(), message: message)
        let data = try JSONEncoder().encode(envelope)
        let tempURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }

    public func poll(after: Date?) -> (message: Message, sentAt: Date)? {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        if let after, envelope.sentAt <= after { return nil }
        return (envelope.message, envelope.sentAt)
    }

    private struct Envelope: Codable {
        let sentAt: Date
        let message: Message
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter CaptureControlChannelTests`
Expected: PASS（4件）

- [ ] **Step 5: commit**

```bash
git add Sources/NotetakeCore/Capture/CaptureControlChannel.swift Tests/NotetakeCoreTests/CaptureControlChannelTests.swift
git commit -m "$(cat <<'EOF'
feat(capture): add file-based control channel for cross-process messages

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 6: RawAudioWriter / RawAudioReader

**Files:**
- Create: `Sources/NotetakeCore/Capture/RawAudioWriter.swift`
- Create: `Sources/NotetakeCore/Capture/RawAudioReader.swift`
- Test: `Tests/NotetakeCoreTests/RawAudioWriterReaderTests.swift`

**Interfaces:**
- Consumes: `RawAudioFrame`（Task 1）
- Produces: `RawAudioWriter`（`init(fileURL:) throws`、`write(sampleRate:channelCount:samples:) throws`、`close()`）。`RawAudioReader.readFrames(fileURL:from:) throws -> (frames: [RawAudioFrame], newOffset: Int)`

- [ ] **Step 1: 失敗するテストを書く**

```swift
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter RawAudioWriterReaderTests`
Expected: FAIL

- [ ] **Step 3: 最小実装を書く**

```swift
// Sources/NotetakeCore/Capture/RawAudioWriter.swift
import Foundation

public final class RawAudioWriter {
    private let handle: FileHandle

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        _ = try handle.seekToEnd()
    }

    public func write(sampleRate: Double, channelCount: Int, samples: [Float]) throws {
        let frame = RawAudioFrame(sampleRate: sampleRate, channelCount: channelCount, samples: samples)
        try handle.write(contentsOf: frame.encoded())
    }

    public func close() {
        try? handle.close()
    }
}
```

```swift
// Sources/NotetakeCore/Capture/RawAudioReader.swift
import Foundation

public enum RawAudioReader {
    public static func readFrames(fileURL: URL, from offset: Int) throws -> (frames: [RawAudioFrame], newOffset: Int) {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return ([], offset)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let tail = handle.readDataToEndOfFile()
        var frames: [RawAudioFrame] = []
        var cursor = 0
        while let (frame, nextOffset) = RawAudioFrame.decode(from: tail, at: cursor) {
            frames.append(frame)
            cursor = nextOffset
        }
        return (frames, offset + cursor)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter RawAudioWriterReaderTests`
Expected: PASS（4件）

- [ ] **Step 5: commit**

```bash
git add Sources/NotetakeCore/Capture/RawAudioWriter.swift Sources/NotetakeCore/Capture/RawAudioReader.swift Tests/NotetakeCoreTests/RawAudioWriterReaderTests.swift
git commit -m "$(cat <<'EOF'
feat(capture): add raw audio frame writer and offset-resumable reader

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 7: `notetaked capture-daemon` subcommand

**Files:**
- Create: `Sources/notetaked/Capture/CaptureSessionRunner.swift`
- Create: `Sources/notetaked/Commands/CaptureDaemonCommand.swift`
- Modify: `Sources/notetaked/Notetaked.swift`（or existing `@main` entry point — subcommand登録。実ファイル名は`Sources/notetaked/`直下の`@main struct Notetaked: AsyncParsableCommand`定義箇所を検索して`subcommands`配列に`CaptureDaemon.self`を追加する）

**Interfaces:**
- Consumes: `MicCapture`/`SystemAudioCapture`（既存、`AudioCapture`準拠）、`RawAudioWriter`（Task 6）、`CaptureControlChannel<CaptureCommand>`/`CaptureControlChannel<CaptureEvent>`（Task 4, 5）、`Heartbeat.write(to:)`/`CaptureStatePaths`（Task 3）
- Produces: `CaptureSessionRunner`（actor、`start(directory:sources:inputDeviceUID:onFallback:) throws`、`stop()`、`isRunning(directory:) -> Bool`）

このプロセスはセッションの有無によらず常駐し、5秒ごとに`CaptureStatePaths.captureHeartbeatURL`へ心拍を書き、0.2秒ごとに`CaptureStatePaths.captureCommandURL`をポーリングして`CaptureCommand`を処理する。`SIGTERM`受信時はgracefulに現在のsessionを`stop()`してから`exit(0)`する。

- [ ] **Step 1: `CaptureSessionRunner`を書く**

```swift
// Sources/notetaked/Capture/CaptureSessionRunner.swift
import Foundation
import AVFoundation
import class NotetakeCore.RawAudioWriter
import enum NotetakeCore.CaptureSessionPaths

actor CaptureSessionRunner {
    private var micCapture: MicCapture?
    private var systemCapture: SystemAudioCapture?
    private var micWriter: RawAudioWriter?
    private var systemWriter: RawAudioWriter?
    private(set) var currentDirectory: URL?

    func start(directory: URL, sources: [String], inputDeviceUID: String?, onFallback: @escaping @Sendable () -> Void) throws {
        if currentDirectory == directory { return }
        stop()
        currentDirectory = directory
        if sources.contains("mic") {
            let writer = try RawAudioWriter(fileURL: CaptureSessionPaths.rawFileURL(sessionDirectory: directory, source: "mic"))
            let capture = MicCapture(pinnedUID: inputDeviceUID, onFallback: onFallback)
            try capture.start { [weak writer] buffer in
                Self.append(buffer: buffer, to: writer)
            }
            micWriter = writer
            micCapture = capture
        }
        if sources.contains("system") {
            let writer = try RawAudioWriter(fileURL: CaptureSessionPaths.rawFileURL(sessionDirectory: directory, source: "system"))
            let capture = try SystemAudioCapture()
            try capture.start { [weak writer] buffer in
                Self.append(buffer: buffer, to: writer)
            }
            systemWriter = writer
            systemCapture = capture
        }
    }

    func stop() {
        micCapture?.stop()
        systemCapture?.stop()
        micWriter?.close()
        systemWriter?.close()
        micCapture = nil
        systemCapture = nil
        micWriter = nil
        systemWriter = nil
        currentDirectory = nil
    }

    nonisolated private static func append(buffer: AVAudioPCMBuffer, to writer: RawAudioWriter?) {
        guard let writer, let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameLength * channelCount)
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = channelData[channel][frame]
            }
        }
        try? writer.write(sampleRate: buffer.format.sampleRate, channelCount: channelCount, samples: samples)
    }
}
```

- [ ] **Step 2: `CaptureDaemon`サブコマンドを書く**

```swift
// Sources/notetaked/Commands/CaptureDaemonCommand.swift
import ArgumentParser
import Foundation
import struct NotetakeCore.CaptureControlChannel
import enum NotetakeCore.CaptureCommand
import enum NotetakeCore.CaptureEvent
import enum NotetakeCore.CaptureStatePaths
import enum NotetakeCore.Heartbeat

struct CaptureDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-daemon",
        abstract: "Resident audio-only capture process, isolated from transcription/control")

    func run() async throws {
        let runner = CaptureSessionRunner()
        let commandChannel = CaptureControlChannel<CaptureCommand>(fileURL: CaptureStatePaths.captureCommandURL)
        let eventChannel = CaptureControlChannel<CaptureEvent>(fileURL: CaptureStatePaths.captureEventURL)

        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task {
                await runner.stop()
                exit(0)
            }
        }
        sigtermSource.resume()

        var lastCommandSeenAt: Date?
        while true {
            try? Heartbeat.write(to: CaptureStatePaths.captureHeartbeatURL)
            if let (command, seenAt) = commandChannel.poll(after: lastCommandSeenAt) {
                lastCommandSeenAt = seenAt
                await handle(command, runner: runner, eventChannel: eventChannel)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func handle(
        _ command: CaptureCommand, runner: CaptureSessionRunner,
        eventChannel: CaptureControlChannel<CaptureEvent>
    ) async {
        switch command {
        case .startSession(let directory, let sources, let inputDeviceUID):
            let directoryURL = URL(fileURLWithPath: directory)
            do {
                try await runner.start(directory: directoryURL, sources: sources, inputDeviceUID: inputDeviceUID) {
                    try? eventChannel.send(.inputFallback)
                }
                try? eventChannel.send(.started(directory: directory))
            } catch {
                try? eventChannel.send(.error("\(error)"))
            }
        case .stopSession:
            await runner.stop()
            try? eventChannel.send(.stopped)
        case .quit:
            await runner.stop()
            exit(0)
        }
    }
}
```

`Sources/notetaked/Notetaked.swift`（`@main`の`subcommands:`配列）に`CaptureDaemon.self`を追加する。既存の`Serve.self`等が並んでいる箇所と同じ配列。

- [ ] **Step 3: ビルド確認**

Run: `swift build 2>&1 | grep -i error`
Expected: 空（エラー無し）

- [ ] **Step 4: commit**

```bash
git add Sources/notetaked/Capture/CaptureSessionRunner.swift Sources/notetaked/Commands/CaptureDaemonCommand.swift Sources/notetaked/Notetaked.swift
git commit -m "$(cat <<'EOF'
feat(capture): add capture-daemon subcommand for isolated audio capture

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 8: RawAudioReaderCapture（`AudioCapture`準拠のtail読み実装）

**Files:**
- Create: `Sources/notetaked/Audio/RawAudioReaderCapture.swift`

**Interfaces:**
- Consumes: `RawAudioReader.readFrames(fileURL:from:)`（Task 6）、`AudioCapture`プロトコル（既存、`Sources/notetaked/Audio/AudioCapture.swift`）
- Produces: `RawAudioReaderCapture`（`format: AVAudioFormat`、`currentOffset: Int`、`init(fileURL:startOffset:) async throws`、`start(_:) throws`、`stop()`）

`format`は最初に読めたフレームのsampleRate/channelCountから構築する。`init`は最初のフレームが読めるまで0.1秒間隔でポーリングする（capture-daemon側が書き始めるまでの短い待ち合わせ）。`start(_:)`は0.05秒間隔のポーリングで新規フレームをtail読みし、`handler`へ`AVAudioPCMBuffer`として渡しつつ`currentOffset`を更新する。

- [ ] **Step 1: 実装を書く**

```swift
// Sources/notetaked/Audio/RawAudioReaderCapture.swift
import AVFoundation
import Foundation
import struct NotetakeCore.RawAudioFrame
import enum NotetakeCore.RawAudioReader

enum RawAudioReaderCaptureError: Error {
    case timedOutWaitingForFirstFrame
}

final class RawAudioReaderCapture: AudioCapture, @unchecked Sendable {
    let format: AVAudioFormat
    private let fileURL: URL
    private let lock = NSLock()
    private var offset: Int
    private var pollTask: Task<Void, Never>?

    var currentOffset: Int {
        lock.lock()
        defer { lock.unlock() }
        return offset
    }

    init(fileURL: URL, startOffset: Int, waitTimeout: TimeInterval = 10) async throws {
        self.fileURL = fileURL
        self.offset = startOffset
        let deadline = Date().addingTimeInterval(waitTimeout)
        var resolvedFormat: AVAudioFormat?
        while resolvedFormat == nil {
            let (frames, _) = try RawAudioReader.readFrames(fileURL: fileURL, from: startOffset)
            if let first = frames.first {
                resolvedFormat = AVAudioFormat(standardFormatWithSampleRate: first.sampleRate, channels: AVAudioChannelCount(first.channelCount))
            } else if Date() > deadline {
                throw RawAudioReaderCaptureError.timedOutWaitingForFirstFrame
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        format = resolvedFormat!
    }

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pollOnce(handler: handler)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let readFrom: Int = {
            lock.lock()
            defer { lock.unlock() }
            return offset
        }()
        guard let (frames, newOffset) = try? RawAudioReader.readFrames(fileURL: fileURL, from: readFrom),
              !frames.isEmpty else { return }
        for frame in frames {
            guard let frameFormat = AVAudioFormat(
                standardFormatWithSampleRate: frame.sampleRate, channels: AVAudioChannelCount(frame.channelCount)),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: frameFormat, frameCapacity: AVAudioFrameCount(frame.samples.count / frame.channelCount))
            else { continue }
            buffer.frameLength = buffer.frameCapacity
            guard let channelData = buffer.floatChannelData else { continue }
            for i in 0..<Int(buffer.frameLength) {
                for channel in 0..<frame.channelCount {
                    channelData[channel][i] = frame.samples[i * frame.channelCount + channel]
                }
            }
            handler(buffer)
        }
        lock.lock()
        offset = newOffset
        lock.unlock()
    }
}
```

- [ ] **Step 2: ビルド確認**

Run: `swift build 2>&1 | grep -i error`
Expected: 空

- [ ] **Step 3: commit**

```bash
git add Sources/notetaked/Audio/RawAudioReaderCapture.swift
git commit -m "$(cat <<'EOF'
feat(capture): add AudioCapture implementation that tails raw capture files

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 9: ServeSessionをcapture-daemon経由に切り替える

**Files:**
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift`

**Interfaces:**
- Consumes: `RawAudioReaderCapture`（Task 8）、`CaptureCommand`/`CaptureEvent`/`CaptureControlChannel`（Task 4, 5）、`CaptureCheckpoint`/`CaptureSessionPaths`/`CaptureStatePaths`（Task 2, 3）
- Produces: `ServeSession`の`startCapture(resumePrefix:)`/`stopCapture()`/`handleFinal`の新しい振る舞い、`resumeIfNeeded()`（新規public method）

### 変更点

1. **プロパティ追加**（既存`private var streams: [RunningStream] = []`等の近くに追加）:

```swift
private let captureCommandChannel = CaptureControlChannel<CaptureCommand>(fileURL: CaptureStatePaths.captureCommandURL)
private let captureEventChannel = CaptureControlChannel<CaptureEvent>(fileURL: CaptureStatePaths.captureEventURL)
private var lastCaptureEventSeenAt: Date?
private var captureEventPollTask: Task<Void, Never>?
private var checkpoint = CaptureCheckpoint()
private var checkpointURLs: [String: URL] = [:]  // source name -> checkpoint file URL
```

2. **`init`の末尾**（既存`self.sessions = SessionIndex.scan(...)`の後）で、inputFallbackイベントのポーリングを常時起動する:

```swift
captureEventPollTask = Task { [weak self] in
    while let self, !Task.isCancelled {
        await self.pollCaptureEvents()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
```

```swift
private func pollCaptureEvents() async {
    guard let (event, seenAt) = captureEventChannel.poll(after: lastCaptureEventSeenAt) else { return }
    lastCaptureEventSeenAt = seenAt
    if case .inputFallback = event {
        await handleInputFallback()
    }
}
```

3. **`startCapture()`のシグネチャを`private func startCapture(resumePrefix: String? = nil) async -> Bool`に変更**し、既存の「`SessionStore.prefix`で衝突回避しながら決める」ロジックは`resumePrefix == nil`の時だけ実行、resume時は`resumePrefix`をそのまま使う。

4. **mic/systemの`AudioCapture`構築を置き換える**。既存コード（`.mic` → `MicCapture(...)`、`.system` → `try SystemAudioCapture()`）を、下記のように`capture-daemon`へ`startSession`を送ってから`RawAudioReaderCapture`を構築する形に変更する:

```swift
let sessionDirectory = CaptureSessionPaths.sessionDirectory(prefix: prefix)
let sourceNames = sourceOption.sources.map { $0.source == .system ? "system" : "mic" }
try captureCommandChannel.send(.startSession(directory: sessionDirectory.path, sources: sourceNames, inputDeviceUID: inputDeviceUID))

// 各sourceについて（.mic / .system 双方で共通）:
let sourceName = source == .system ? "system" : "mic"
let rawFileURL = CaptureSessionPaths.rawFileURL(sessionDirectory: sessionDirectory, source: sourceName)
let checkpointURL = CaptureSessionPaths.checkpointFileURL(sessionDirectory: sessionDirectory, source: sourceName)
checkpointURLs[sourceName] = checkpointURL
// checkpointは actor 内の in-memory プロパティではなく、必ずディスクから読み直す
// （process がクラッシュ後に再構築された ServeSession は in-memory checkpoint を持たないため）
let startOffset = CaptureCheckpoint.load(from: checkpointURL).offsets[sourceName] ?? 0
checkpoint.offsets[sourceName] = startOffset
let capture = try await RawAudioReaderCapture(fileURL: rawFileURL, startOffset: startOffset)
```

この`capture`（`any AudioCapture`準拠）を、既存どおり`CaptureStream(source:capture:locale:diarizerModels:)`へ渡す。`.watch`は既存のまま`sourceNotImplemented`。

**必要なimport**（ファイル冒頭、既存の`import class NotetakeCore.AudioConverter`等と同じ書式で追加）:
```swift
import struct NotetakeCore.CaptureCheckpoint
import enum NotetakeCore.CaptureSessionPaths
import enum NotetakeCore.CaptureStatePaths
import enum NotetakeCore.CaptureCommand
import enum NotetakeCore.CaptureEvent
import struct NotetakeCore.CaptureControlChannel
```

5. **`handleFinal`でcheckpointを更新**。既存の`store.append(.segment(segment))`の直後に、該当sourceの`RawAudioReaderCapture.currentOffset`を`checkpoint.offsets[sourceName]`へ反映し`checkpoint.save(to: checkpointURLs[sourceName]!)`を呼ぶ（`RunningStream`に`rawCapture: RawAudioReaderCapture?`を追加し、`source`から引けるようにする）。

6. **`stopCapture()`の末尾**で`captureCommandChannel.send(.stopSession)`を呼び、`checkpointURLs`をクリアする。

7. **`startCapture()`の成功時**（`self.recording = true`を設定した直後、`start()`/`rotate()`どちらから呼ばれても同じ場所を通る）、`CaptureStatePaths.currentSessionMarkerURL`へ`{"prefix": store.prefix}`相当のJSONを書く。**`stopCapture()`の末尾**（`self.recording = false`を設定した直後）でこのファイルを削除する。`start()`/`stop()`自体には手を入れない — `rotate()`は`stopCapture()`→`startCapture()`を直接呼ぶため、marker書き込み/削除をそちらに置くと`rotate()`時にmarkerが更新されない。

8. **`resumeIfNeeded()`（新規public method、actor外から`await session.resumeIfNeeded()`で呼ぶ）**:

```swift
func resumeIfNeeded() async {
    guard let data = try? Data(contentsOf: CaptureStatePaths.currentSessionMarkerURL),
          let marker = try? JSONDecoder().decode(SessionMarker.self, from: data) else { return }
    _ = await startCapture(resumePrefix: marker.prefix)
}

private struct SessionMarker: Codable { let prefix: String }
```

- [ ] **Step 1: ビルド確認**

Run: `swift build 2>&1 | grep -i error`
Expected: 空

- [ ] **Step 2: `swift test`（既存テストの回帰確認）**

Run: `swift test`
Expected: 既存テスト全件PASS（`ServeSession`自体は`notetaked`側でテスト対象外だが、`NotetakeCore`側の型は変更していないため既存テストは無関係に通る）

- [ ] **Step 3: commit**

```bash
git add Sources/notetaked/Pipeline/ServeSession.swift
git commit -m "$(cat <<'EOF'
feat(capture): route ServeSession audio input through capture-daemon

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 10: ServeCommandの心拍ループと起動時resume

**Files:**
- Modify: `Sources/notetaked/Commands/ServeCommand.swift`

**Interfaces:**
- Consumes: `Heartbeat.write(to:)`/`CaptureStatePaths.processHeartbeatURL`（Task 3）、`ServeSession.resumeIfNeeded()`（Task 9）

### 変更点

`runServe`内、`ServeSession`構築直後（既存の`SIGINT/SIGTERM`ハンドラ設定より前）に以下を追加する:

```swift
await session.resumeIfNeeded()

let heartbeatTask = Task {
    while !Task.isCancelled {
        try? NotetakeCore.Heartbeat.write(to: NotetakeCore.CaptureStatePaths.processHeartbeatURL)
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
}
defer { heartbeatTask.cancel() }
```

（`import enum NotetakeCore.CaptureStatePaths` / `import enum NotetakeCore.Heartbeat`をファイル先頭に追加）

- [ ] **Step 1: 実装**

上記の追加を`runServe`メソッドへ反映する。

- [ ] **Step 2: ビルド確認**

Run: `swift build 2>&1 | grep -i error`
Expected: 空

- [ ] **Step 3: commit**

```bash
git add Sources/notetaked/Commands/ServeCommand.swift
git commit -m "$(cat <<'EOF'
feat(capture): emit process heartbeat and auto-resume session on serve startup

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 11: メニューバーappで2プロセスを監視する

**Files:**
- Create: `Apps/Notetake/CaptureDaemonSupervisor.swift`
- Modify: `Apps/Notetake/AppModel.swift`
- Modify: `Apps/project.yml`（`Notetake`ターゲットの`sources`に`../Sources/notetaked/...`由来の新規参照は不要。`Apps/Notetake/CaptureDaemonSupervisor.swift`は`Apps/Notetake`配下なので既存の`sources: [Notetake]`グロブに含まれるはずだが、`project.yml`を確認し含まれていなければ追加する）

**Interfaces:**
- Consumes: `Heartbeat.currentStatus(of:threshold:)`/`CaptureStatePaths.captureHeartbeatURL`/`.processHeartbeatURL`（Task 3。Mac appは`NotetakeCore`をimport可能な既存構成——`AppModel.swift`は既に`NotetakeCore`の型（`Event`/`Command`）をimportしている）
- Produces: `CaptureDaemonSupervisor`（`start()`, `stop()`, `isHealthy: Bool`）

### `CaptureDaemonSupervisor`（新規）

```swift
// Apps/Notetake/CaptureDaemonSupervisor.swift
import Foundation
import NotetakeCore

@MainActor
final class CaptureDaemonSupervisor {
    private var process: Process?
    private let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["capture-daemon"]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.process = nil }
        }
        try? process.run()
        self.process = process
    }

    var isHealthy: Bool {
        Heartbeat.currentStatus(of: CaptureStatePaths.captureHeartbeatURL, threshold: 15) == .alive
    }

    func gracefulRestart() async {
        if let pid = process?.processIdentifier {
            kill(pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        start()
    }
}
```

### `AppModel.swift`の変更

1. プロパティ追加（`private var client: DaemonClient?`の近く）:

```swift
private let captureSupervisor: CaptureDaemonSupervisor
private var heartbeatMonitorTask: Task<Void, Never>?
```

`init`で`captureSupervisor = CaptureDaemonSupervisor(executableURL: <notetakedの実行ファイルURL、既存startClientが使っているものと同じ導出ロジックを再利用>)`を設定する。

2. `ensureDaemon()`の冒頭（`guard !isShuttingDown else { return }`の直後）に`captureSupervisor.start()`を追加する（`notetaked serve`と同様、既に起動済みなら`start()`は何もしない）。

3. アプリ起動時（`AppModel`の`init`の末尾、または既存の`ensureDaemon()`初回呼び出し箇所）で心拍監視ループを開始する:

```swift
heartbeatMonitorTask = Task { @MainActor [weak self] in
    while let self, !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !self.isShuttingDown else { continue }
        if !self.captureSupervisor.isHealthy {
            await self.captureSupervisor.gracefulRestart()
        }
        if NotetakeCore.Heartbeat.currentStatus(of: NotetakeCore.CaptureStatePaths.processHeartbeatURL, threshold: 15) == .stale,
           self.daemonRunning {
            self.lastError = "processがハングしたため再起動します"
            await self.client?.terminate(wasRecording: self.isRecording)
            self.scheduleRestart()
        }
    }
}
```

4. `shutdownDaemon()`の末尾で`heartbeatMonitorTask?.cancel()`と、`capture-daemon`側の終了（`captureSupervisor`にも`SIGTERM`猶予付きの`stop()`メソッドを追加し呼び出す）を行う。

- [ ] **Step 1: 実装**

上記2ファイルを反映する。

- [ ] **Step 2: `make app`でビルド確認**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/notetaked && make app 2>&1 | tail -30`
Expected: ビルド成功（エラー無し）

- [ ] **Step 3: commit**

```bash
git add Apps/Notetake/CaptureDaemonSupervisor.swift Apps/Notetake/AppModel.swift Apps/project.yml
git commit -m "$(cat <<'EOF'
feat(capture): supervise capture-daemon and detect process hangs via heartbeat

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Task 12: `make verify` + HANDOFF更新 + 実機検証チェックリスト

**Files:**
- Modify: `HANDOFF.md`

**Interfaces:** なし（検証と記録のみ）

- [ ] **Step 1: `make verify`を実行し全件の結果を受け取る**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/notetaked && make verify > .build/logs/verify-run.log 2>&1; echo "exit=$?"`
Expected: `exit=0`、`.build/logs/verify-run.log`の最終行が`verify: OK`

- [ ] **Step 2: 失敗があれば全件を受け取ってから修正**（1件ずつ潰さない。`.claude/skills/verify/SKILL.md`の報告フォーマットに従う）

- [ ] **Step 3: HANDOFF.mdに実装状況を記録**（`make verify`通過を確認してから「実装済み」と書く。実機検証はまだのため「未検証」と明記する）

```markdown
- **issue #15 プロセス分離を実装・`make verify`通過、実機検証は未実施（2026-09-19）**: `notetaked capture-daemon`（新設・マイク/システム音声のtapのみ）と`notetaked serve`（既存、話者分離/文字起こし/出力/制御）の2プロセスに分離。生音声はOS tmp（`notetake-capture/<prefix>/`）へ自己記述フレーム形式で追記、`process`はtail読みし`finalな発話確定ごとにcheckpoint（`<source>.checkpoint`）を更新。両プロセスは`~/Library/Application Support/Notetake/state/`配下の固定パスへ5秒ごとに心拍ファイルを書き、メニューバーappが15秒無更新でハングとみなしgraceful(5秒猶予)→forced再起動する。spec: `docs/superpowers/specs/2026-09-19-capture-process-separation-design.md`、plan: `docs/superpowers/plans/2026-09-19-capture-process-separation.md`
  - **実機検証が必要な項目**: (1) `notetaked serve`を`kill -9`し、メニューバーappが自動再起動、checkpointから再開して欠落が最小限であることを確認 (2) `notetaked capture-daemon`を`kill -9`し、心拍staleを検知してメニューバーappが再起動することを確認 (3) 長時間セッション（数時間）でtmp領域の増加がOSの管理範囲内であることを確認 (4) AirPods等のpinデバイス切断時、`capture-daemon`から`process`への`inputFallback`イベント伝播が既存のフォールバック挙動（#14/#入力デバイス選択機能）と同様に動くことを確認"
```

- [ ] **Step 4: commit**

```bash
git add HANDOFF.md
git commit -m "$(cat <<'EOF'
docs(handoff): record capture process separation implementation status

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RGY4aPBvSVbna2jHr6uXvj
EOF
)"
```

---

## Self-Review Notes（このplanを書いた時点での確認）

- **spec covered**: アーキテクチャ概要→Task 7/9/11、データフロー/checkpoint→Task 1/2/6/9、heartbeat/復旧→Task 3/11、制御チャンネル→Task 4/5/9/10、テスト方針→各Taskのユニットテスト＋Task 12の実機チェックリスト、運用上の前提（セッション回しっぱなし）→Task 9のresumeIfNeeded/Task 10で対応
- **plan作成中に見つかった、spec本文に明記の無い設計判断**: (1) spec 4節は`process`↔`capture`間を「既存と同じstdio NDJSON形式」としていたが、両プロセスはメニューバーappの個別の子プロセス（兄弟関係）でありstdioで直結できないため、Task 5の`CaptureControlChannel`（アトミックファイル書き込み＋ポーリング）に置き換えた。ソケット/FIFO/シグナルより実装リスクが低く、既存のcheckpoint/heartbeatと同じ「ファイル+ポーリング」パターンへ統一できる利点がある (2) `process`がクラッシュ後に録音セッションを自動再開する経路がspecに無かったため、Task 9/10の`resumeIfNeeded()`＋`current-session.json`マーカーを追加した
- **型/シグネチャの一貫性**: `CaptureCommand`/`CaptureEvent`（Task 4）は Task 7（capture-daemon側の送受信）とTask 9（ServeSession側の送受信）で同一シグネチャを使用。`RawAudioReaderCapture.currentOffset`（Task 8）はTask 9のcheckpoint更新でそのまま参照
