# 段階1「取り込みと生音声」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** capture-daemonが16kHz monoの生音声と時刻の基準点を書き、止まった取り込みを自動で再開する。serveは収録中に文字起こしだけを行い、壁時計に合った時刻で発話を出す。

**Architecture:** capture-daemonは、sourceごとの`SourceRecorder`へ音声を渡す。`SourceRecorder`は記録用のqueueで16kHz monoへ変換し、`<source>.pcm`と`<source>.meta.jsonl`へ書く。serveとcapture-daemonは、serveが書く`capture-desired.json`と、capture-daemonが書く`capture-actual.json`の2つのファイルで受け渡す。serveは`LiveTranscription`で`.pcm`の末尾を追いかけて文字起こしし、anchorで時刻を壁時計へ直す。収録中の話者分離、再開位置の記録、命令とeventのファイルは取り除く。

**Tech Stack:** Swift 6（SwiftPM、strict concurrency）、AVFoundation（AVAudioEngine、AVAudioConverter）、AudioToolbox（AUHAL）、ScreenCaptureKit、Speech（SpeechAnalyzer）、IOKit（Task 7を行う場合だけ）、Swift Testing

**Spec:** `docs/superpowers/specs/2026-10-03-batch-finalize-redesign-design.md`の段階1。段階2（確定処理）と段階3（構造の整理）の項目はこの計画に入れない。

## Global Constraints

- macOS 26以上（`Package.swift`の`platforms`）。Swift 6のstrict concurrencyで警告ゼロ。`make verify`は警告を不合格にする
- 新しい外部依存を足さない。FluidAudio 0.15.7は段階2の確定処理で使うため、`notetaked`targetの依存に残す
- 生音声は`<tmp>/notetake-capture/<prefix>/`に置く。serveが`session.json`を、capture-daemonが`<source>.pcm`（16kHz monoのFloat32 little endian、header無し）と`<source>.meta.jsonl`（anchor、device、stateの行）を書く。notetakedは生音声を消さない
- anchor: bufferの先頭sampleの壁時計（受け取った時刻からbufferの長さを引いた時刻）が、直前のanchorから16kHzで進めた時刻と250msを超えてずれたら書く
- 状態ファイルは`~/Library/Application Support/Notetake/state/`に置く。`capture-desired.json`はserveが書き、`capture-actual.json`はcapture-daemonが1秒ごとに書く（更新時刻が心拍）。`process.heartbeat`はserveが書く。書き込みはすべて`AtomicFile.write`（同じディレクトリの一時ファイルへ書いてからrename）を通す
- 間隔: 望む状態の確認200ms、実状態の書き込みと読み込み1秒、実状態を古いと見なすまで5秒、ライブの読み込み100ms、system音声の作り直し5秒、micの再試行1・2・4・8・16・30秒（以後30秒）、appがcapture-daemonをハングと見なすまで15秒
- 収録中の発話には話者を付けない。ラベルはmicが所有者名、systemが「リモート」（`ServeSession.SourceOption`の規則）
- `timed.jsonl`の記録形式は変えない。`session_end`、`finalized`、`pass`、`run`は段階2で足す
- commentには、いまのcodeが守る前提とその理由だけを書く。issue番号、過去の不具合、検証の経緯は書かない
- 発話や音声を失う失敗は、`error` event、`log` event、実状態の`last_error`のどれかに出す。`try?`は失敗してよい処理（一時ファイルの削除、ファイルを閉じる処理、止まっているstreamの停止、待機の取り消し）に限る
- test fixtureに実在の人名を書かない。山田太郎、私、`external`のような架空の値を使う
- 日本語と英数字の間に空白を入れない（comment、doc、commit本文）
- 進め方: TDDの赤と緑は`swift test --filter '<テスト名の正規表現>'`で確かめる。taskの終わりに`make verify`を通す（Haiku subagent）。subagentはgitを変更しない（commit、`git rm`、`git add`をしない）。ファイルの削除は`rm`で行い、controllerが`git add`（削除は`git add -A <path>`）と`git commit`で反映する。`make verify`の結果は`.claude/skills/verify`の手順で読む（実行前に前回のlogを消すため、古い成功を読み違えない）。commit messageの末尾に`Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`を付ける
- `make daemon`の署名が終わる前にbinaryを起動しない（Gatekeeperがbinaryをゴミ箱へ移す）。実機の確認はビルドの完了後に行う
- 前面の`sleep`はClaude Codeで使えない。待ちを含む実機の確認は、scriptを`run_in_background`で走らせて終了の知らせを待つ

## Review Focus

1. **capture-daemonが書き込みの途中で落ちて再起動した**: `.pcm`の末尾に4byteに満たない端数が、`.meta.jsonl`の末尾に改行の無い行が残る。再起動後の追記はsampleと行の境目から始まり、それまでの音声と時刻はそのまま読めるべき → Task 4の`recorderReopensAPartlyWrittenRecordingAtSampleAndLineBoundaries`
2. **音声が途切れた後や、入力のformatが変わった後の時刻**: 変換器は出力を約70ms遅らせて出す。anchorを書き込み済みのsample数に付けると、途切れの前の音が途切れの後の時刻になる。anchorは、bufferの先頭が実際に入るsample番号に付くべき → Task 4の`recorderAnchorsAGapButNotJitter`と`recorderAnchorsTheFirstSampleAfterAFormatChangeAndGap`
3. **区切りの瞬間の音声**: 区切りでは取り込みを止めない。前の収録と新しい収録のsample数の合計が受け取った音声と一致し、新しい収録は切り替えた時点のanchorとdeviceから始まるべき → Task 4の`recorderSwitchesDirectoriesWithoutLosingSamples`、Task 5の`controllerStartsSourcesAndSwitchesDirectoriesWithoutRestarting`
4. **固定した入力機器が外れた**: appへの`input_reset`は外れるたびに1回だけ送り、毎秒送り続けない → Task 10の`actualWatcherSendsInputResetOncePerFallback`
5. **capture-daemonが止まった、または望む状態のファイルが壊れた**: 実状態が5秒更新されなければ「capture-daemonが応答していません」を出す。壊れた望む状態のファイルでは、収録を止めずに今の取り込みを続けるべき → Task 10の`actualWatcherTreatsStaleOrMissingStateAsUnresponsive`、Task 3の`desiredStateWatcherReportsOnlyChanges`

## ファイルの構成

| ファイル | task | 責務 |
|---|---|---|
| `Sources/NotetakeCore/Capture/AtomicFile.swift` | 1 | 原子的な書き込み（`AtomicFile`）と状態ファイルの読み書き（`JSONFile`） |
| `Sources/NotetakeCore/Capture/CapturePCM.swift` | 2 | 生音声の形式。sample数とmsの換算、Float32の符号化 |
| `Sources/NotetakeCore/Capture/CaptureMeta.swift` | 2 | `.meta.jsonl`の行（`CaptureMetaLine`）と取り込みの状態（`CaptureSourceState`） |
| `Sources/NotetakeCore/Capture/CaptureTimeline.swift` | 2 | sample番号から壁時計と入力機器を求める`CaptureTimeline`、書き手のanchorの判定`AnchorClock` |
| `Sources/NotetakeCore/Capture/CaptureSessionInfo.swift` | 2 | `session.json` |
| `Sources/NotetakeCore/Capture/CaptureState.swift` | 3 | 望む状態、実状態、望む状態のファイルの見張り |
| `Sources/NotetakeCore/Capture/RetryBackoff.swift` | 5 | micの再試行の間隔 |
| `Sources/NotetakeCore/Capture/DisplaySleepPolicy.swift` | 7 | 消灯を防ぎ続けるかの判断（Task 7を行う場合だけ） |
| `Sources/NotetakeCore/Capture/RawAudioTail.swift` | 8 | 追記され続ける生音声の読み手と、ライブの時刻の対応 |
| `Sources/NotetakeCore/Control/CaptureStatus.swift` | 10 | statusで伝える取り込みの状態と、実状態の変化の検出 |
| `Sources/NotetakeCore/Render/CaptureStatusLabel.swift` | 13 | メニューの取り込みの状態の文 |
| `Sources/notetaked/Capture/MonoResampler.swift` | 4 | callbackで受け取ったbufferの写しと、16kHz monoへの変換 |
| `Sources/notetaked/Capture/SourceRecorder.swift` | 4 | 記録用queueでの書き込みとanchorの判定。取り込みが渡す先の`CaptureSink` |
| `Sources/notetaked/Capture/CaptureController.swift` | 5 | 望む状態に取り込みと書き込み先を合わせ、実状態を返す。取り込みの`SourceCapture` |
| `Sources/notetaked/Capture/DisplaySleepGuard.swift` | 7 | 消灯を防ぐassertionの保持（Task 7を行う場合だけ） |
| `Sources/notetaked/Audio/SystemAudioCapture.swift` | 5 | ScreenCaptureKitの取り込みと自動の作り直し（置き換え） |
| `Sources/notetaked/Audio/MicCapture.swift` | 5 | AVAudioEngineとAUHALの取り込みと再試行（置き換え） |
| `Sources/notetaked/Commands/CaptureDaemonCommand.swift` | 5、7 | capture-daemonの繰り返し（置き換え） |
| `Sources/notetaked/Pipeline/LiveTranscription.swift` | 9 | 1つのsourceのライブの文字起こし |
| `Sources/notetaked/Pipeline/ServeSession.swift` | 11 | 収録の開始・停止・区切り、望む状態の書き込み、実状態の読み込み（前半を置き換え） |
| `Sources/notetaked/Commands/ServeCommand.swift` | 11 | serveの起動（置き換え） |
| `.claude/skills/recordings/scripts/pcm-coverage.py` | 6 | 生音声の、壁時計の区間ごとの音声の量と音量 |
| `.claude/skills/daemon-realtest/scripts/display-sleep-check.sh` | 6 | 消灯中の取り込みの確認 |
| `.claude/skills/daemon-realtest/scripts/cli-cycle.sh`、`cli-cycle-report.py` | 11 | CLIでの一巡と、その判定 |

取り除くもの（Task 5とTask 12）: `CaptureSessionRunner`、`capture`subcommand、`AudioCapture`、`RawAudioReaderCapture`、`CaptureStream`、`RawAudioFrame`・`RawAudioReader`・`RawAudioWriter`、`CaptureCheckpoint`、`CaptureControlChannel`、`CaptureCommand`・`CaptureEvent`、`NotetakeDiarization`target（`Diarizer`）、`Aligner`、`SpeakerTurn`、`SpeakerRegistry`、`ProfileNameAnnouncer`、`SpeakerProfileStore`、`SessionStore.writeSpeakers`、`Reconciler`の話者の継承と二次解決、`.claude/skills/recordings/scripts/fallback-diff.sh`

段階1の途中では、収録中の話者分離が無くなり、`final.md`に話者が付かない。ライブパネルの改名popoverは、話者の付いた発話が無いため出ない。命名は段階2で「収録の話者」windowへ移す。Task 5からTask 11の間は、capture-daemonが新しい形式で書き、serveが古い形式を読むため、appからの収録は動かない。

---

### Task 1: 原子的な書き込みと状態ファイルの読み書き

状態ディレクトリの書き込みを1つの補助関数にまとめ、心拍ファイルの一時ファイルが残る不具合を直す。いまの`Heartbeat.write`は、`.atomic`で一時ファイルへ書いた後にさらに`replaceItemAt`で入れ替え、その失敗を呼び出し側の`try?`が捨てるため、一時ファイルが残る。

**Files:**
- Create: `Sources/NotetakeCore/Capture/AtomicFile.swift`
- Modify: `Sources/NotetakeCore/Capture/Heartbeat.swift`（`write(to:now:)`）
- Test: `Tests/NotetakeCoreTests/AtomicFileTests.swift`

**Interfaces:**
- Produces: `AtomicFile.write(_ data: Data, to url: URL) throws`。`JSONFile.write<Value: Encodable>(_ value: Value, to url: URL) throws`（sortedKeys、slashを逃がさない）。`JSONFile.read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value?`（ファイルが無ければnil、解釈できなければthrow）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/AtomicFileTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func atomicWriteCreatesParentAndReplacesContent() throws {
    let directory = temporaryDirectory("atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nested/state.json")

    try AtomicFile.write(Data("one".utf8), to: url)
    try AtomicFile.write(Data("two".utf8), to: url)

    #expect(try String(contentsOf: url, encoding: .utf8) == "two")
}

@Test func atomicWriteLeavesNoTemporaryFiles() throws {
    let directory = temporaryDirectory("atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("state.json")

    for index in 0..<50 {
        try AtomicFile.write(Data("\(index)".utf8), to: url)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
}

@Test func atomicWriteFailureRemovesTemporaryFile() throws {
    let directory = temporaryDirectory("atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocked = directory.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: blocked.appendingPathComponent("inside"))

    #expect(throws: (any Error).self) {
        try AtomicFile.write(Data("y".utf8), to: blocked)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["blocked"])
}

private struct Sample: Codable, Equatable {
    var name: String
}

@Test func jsonFileRoundTripsAndReportsMissingAndBrokenFiles() throws {
    let directory = temporaryDirectory("json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("state.json")

    #expect(try JSONFile.read(Sample.self, from: url) == nil)

    try JSONFile.write(Sample(name: "山田太郎"), to: url)
    #expect(try JSONFile.read(Sample.self, from: url) == Sample(name: "山田太郎"))

    try AtomicFile.write(Data("{".utf8), to: url)
    #expect(throws: (any Error).self) {
        _ = try JSONFile.read(Sample.self, from: url)
    }
}

@Test func heartbeatWriteLeavesNoTemporaryFiles() throws {
    let directory = temporaryDirectory("heartbeat")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("process.heartbeat")

    for _ in 0..<20 {
        try Heartbeat.write(to: url)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["process.heartbeat"])
    #expect(Heartbeat.currentStatus(of: url, threshold: 15) == .alive)
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'atomicWrite|jsonFileRoundTrips|heartbeatWriteLeaves'`
Expected: buildが`cannot find 'AtomicFile' in scope`で失敗する

- [ ] **Step 3: 実装する**

`Sources/NotetakeCore/Capture/AtomicFile.swift`:

```swift
import Foundation

/// 読み手が書きかけの内容を見ないよう、同じディレクトリの一時ファイルへ書いてからrenameで置き換える。
/// 置き換えに失敗した時は一時ファイルを消すため、ディレクトリに一時ファイルが残らない
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL)
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

/// 状態ファイル（JSON）の読み書き。書き込みは`AtomicFile`を通す
public enum JSONFile {
    public static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(value), to: url)
    }

    /// ファイルが無ければnil。中身を解釈できなければthrowする
    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
```

`Sources/NotetakeCore/Capture/Heartbeat.swift`の`write(to:now:)`を置き換える:

```swift
    public static func write(to url: URL, now: Date = Date()) throws {
        try AtomicFile.write(Data(ISO8601DateFormatter().string(from: now).utf8), to: url)
    }
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'atomicWrite|jsonFileRoundTrips|heartbeatWrite|statusIs|currentStatus|writeThenCurrent|statePaths'`
Expected: PASS

- [ ] **Step 5: 検証ゲート**

Run: `make verify`（Haiku subagent、`.claude/skills/verify`）。skillは実行前に前回のlogを消す。`verify-run.log`が無い、または`exit=`が出ていなければ失敗として扱う
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/NotetakeCore/Capture/AtomicFile.swift Sources/NotetakeCore/Capture/Heartbeat.swift Tests/NotetakeCoreTests/AtomicFileTests.swift
git commit -m "$(cat <<'MSG'
feat(core): write state files through one atomic helper

Heartbeat files were written atomically and then swapped again with
replaceItemAt, leaving temporary files behind whenever the swap failed.
AtomicFile writes a temporary file in the same directory and renames it
over the target, removing it on failure. JSONFile reads and writes the
state files that serve and capture-daemon will exchange.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 2: 生音声の形式と時刻の基準点

生音声を、16kHz monoのFloat32をheader無しで並べる形式にする。byte offsetを4で割ればsample番号になるため、確定処理（段階2）がファイルをそのまま読める。時刻は`<source>.meta.jsonl`のanchor（sample番号と壁時計の対応）で表し、音声が途切れても時刻がずれないようにする。

**Files:**
- Create: `Sources/NotetakeCore/Capture/CapturePCM.swift`、`Sources/NotetakeCore/Capture/CaptureMeta.swift`、`Sources/NotetakeCore/Capture/CaptureTimeline.swift`、`Sources/NotetakeCore/Capture/CaptureSessionInfo.swift`
- Modify: `Sources/NotetakeCore/Capture/CaptureSessionPaths.swift`（関数を3つ足す。`rawFileURL`と`checkpointFileURL`はTask 12で消す）
- Test: `Tests/NotetakeCoreTests/CaptureFormatTests.swift`

**Interfaces:**
- Consumes: `InputDevice`、`Source`（既存）
- Produces:
  - `CapturePCM.sampleRate`（16_000）、`CapturePCM.bytesPerSample`（4）、`ms(forSamples: Int64) -> Int64`、`samples(forMS: Int64) -> Int64`、`encode(_ samples: [Float]) -> Data`、`decode(_ data: Data) -> [Float]`
  - `enum CaptureSourceState: String, Codable { case recording, retrying, off }`
  - `struct CaptureAnchor { var sample: Int64; var ms: Int64 }`
  - `enum CaptureMetaLine { case anchor(CaptureAnchor); case device(sample: Int64, device: InputDevice); case state(sample: Int64, ms: Int64, state: CaptureSourceState, reason: String?) }`、`encodedLine() throws -> String`、`static decode(line: String) throws -> CaptureMetaLine`
  - `struct CaptureTimeline`: `init(lines:)`、`mutating apply(_:)`、`ms(atSample:) -> Int64?`、`device(atSample:) -> InputDevice?`
  - `struct AnchorClock`: `static toleranceMS`（250）、`mutating anchor(forBufferStartingAt sample: Int64, wallClockMS: Int64) -> CaptureAnchor?`、`mutating reset()`
  - `struct CaptureSessionInfo(outputDirectory:device:deviceName:owner:)`
  - `CaptureSessionPaths.pcmURL(sessionDirectory:source:)`、`metaURL(sessionDirectory:source:)`、`sessionInfoURL(sessionDirectory:)`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/CaptureFormatTests.swift`:

```swift
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
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'pcmConverts|pcmEncodes|metaLines|timeline|anchorClock|sessionInfo'`
Expected: buildが`cannot find 'CapturePCM' in scope`などで失敗する

- [ ] **Step 3: 実装する**

`Sources/NotetakeCore/Capture/CapturePCM.swift`:

```swift
import Foundation

/// capture-daemonが書き、serveと確定処理が読む生音声（`<source>.pcm`）の形式。
/// 16kHz monoのFloat32 little endianをheader無しで並べるため、byte offsetを4で割るとsample番号になる
public enum CapturePCM {
    public static let sampleRate = 16_000
    public static let bytesPerSample = 4

    public static func ms(forSamples samples: Int64) -> Int64 {
        Int64((Double(samples) * 1000 / Double(sampleRate)).rounded())
    }

    public static func samples(forMS ms: Int64) -> Int64 {
        ms * Int64(sampleRate) / 1000
    }

    public static func encode(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * bytesPerSample)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                raw.storeBytes(
                    of: sample.bitPattern.littleEndian, toByteOffset: index * bytesPerSample, as: UInt32.self)
            }
        }
        return data
    }

    /// 4byteに満たない末尾の端数は無視する
    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / bytesPerSample
        return data.withUnsafeBytes { raw in
            (0..<count).map { index in
                Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(fromByteOffset: index * bytesPerSample, as: UInt32.self)))
            }
        }
    }
}
```

`Sources/NotetakeCore/Capture/CaptureMeta.swift`:

```swift
import Foundation

/// 1つのsourceの取り込みの状態
public enum CaptureSourceState: String, Codable, Sendable {
    case recording
    case retrying
    case off
}

/// sample番号と壁時計（epoch ms）の対応
public struct CaptureAnchor: Codable, Equatable, Sendable {
    public var sample: Int64
    public var ms: Int64

    public init(sample: Int64, ms: Int64) {
        self.sample = sample
        self.ms = ms
    }
}

/// `<source>.meta.jsonl`の1行
public enum CaptureMetaLine: Equatable, Sendable {
    /// sample番号と壁時計の対応。その後のsampleは16kHzで進める
    case anchor(CaptureAnchor)
    /// そのsample以降の入力機器。micだけが書く
    case device(sample: Int64, device: InputDevice)
    /// 取り込みの停止と再開、書き込みの失敗の記録。表示と調査に使う
    case state(sample: Int64, ms: Int64, state: CaptureSourceState, reason: String?)
}

extension CaptureMetaLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, sample, ms, device, state, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        let sample = try container.decode(Int64.self, forKey: .sample)
        switch type {
        case "anchor":
            self = .anchor(CaptureAnchor(sample: sample, ms: try container.decode(Int64.self, forKey: .ms)))
        case "device":
            self = .device(sample: sample, device: try container.decode(InputDevice.self, forKey: .device))
        case "state":
            self = .state(
                sample: sample, ms: try container.decode(Int64.self, forKey: .ms),
                state: try container.decode(CaptureSourceState.self, forKey: .state),
                reason: try container.decodeIfPresent(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t, in: container, debugDescription: "unknown meta line type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anchor(let anchor):
            try container.encode("anchor", forKey: .t)
            try container.encode(anchor.sample, forKey: .sample)
            try container.encode(anchor.ms, forKey: .ms)
        case .device(let sample, let device):
            try container.encode("device", forKey: .t)
            try container.encode(sample, forKey: .sample)
            try container.encode(device, forKey: .device)
        case .state(let sample, let ms, let state, let reason):
            try container.encode("state", forKey: .t)
            try container.encode(sample, forKey: .sample)
            try container.encode(ms, forKey: .ms)
            try container.encode(state, forKey: .state)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }

    public func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(line: String) throws -> CaptureMetaLine {
        try JSONDecoder().decode(CaptureMetaLine.self, from: Data(line.utf8))
    }
}
```

`Sources/NotetakeCore/Capture/CaptureTimeline.swift`:

```swift
import Foundation

/// `.meta.jsonl`のanchorとdevice行から、sample番号を壁時計と入力機器へ対応させる
public struct CaptureTimeline: Equatable, Sendable {
    public struct DeviceChange: Equatable, Sendable {
        public var sample: Int64
        public var device: InputDevice
    }

    /// sample番号の昇順
    public private(set) var anchors: [CaptureAnchor] = []
    /// sample番号の昇順
    public private(set) var devices: [DeviceChange] = []

    public init(lines: [CaptureMetaLine] = []) {
        for line in lines {
            apply(line)
        }
    }

    public mutating func apply(_ line: CaptureMetaLine) {
        switch line {
        case .anchor(let anchor):
            let index = anchors.firstIndex { $0.sample > anchor.sample } ?? anchors.count
            anchors.insert(anchor, at: index)
        case .device(let sample, let device):
            let index = devices.firstIndex { $0.sample > sample } ?? devices.count
            devices.insert(DeviceChange(sample: sample, device: device), at: index)
        case .state:
            break
        }
    }

    /// sampleの壁時計。そのsample以前で最後のanchorから16kHzで進めて求める。
    /// 最初のanchorより前のsampleは、最初のanchorから戻して求める。anchorが無ければnil
    public func ms(atSample sample: Int64) -> Int64? {
        guard let anchor = Self.last(in: anchors, atOrBefore: sample, key: \.sample) ?? anchors.first else {
            return nil
        }
        return anchor.ms + CapturePCM.ms(forSamples: sample - anchor.sample)
    }

    /// sampleを拾った入力機器。device行が無ければnil
    public func device(atSample sample: Int64) -> InputDevice? {
        (Self.last(in: devices, atOrBefore: sample, key: \.sample) ?? devices.first)?.device
    }

    private static func last<Element>(
        in elements: [Element], atOrBefore sample: Int64, key: (Element) -> Int64
    ) -> Element? {
        var low = 0
        var high = elements.count
        while low < high {
            let middle = (low + high) / 2
            if key(elements[middle]) <= sample {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : elements[low - 1]
    }
}

/// 書き手のanchorの判定。bufferの先頭sampleの壁時計が、直前のanchorから16kHzで進めた時刻と
/// 250msを超えてずれたら新しいanchorを返す。音声が途切れた場合も、音声の時計が壁時計からずれた場合も
/// この規則で扱う。250msはcallbackの揺らぎより大きく、別の機器の発話を統合する許容幅（1秒）より小さい
public struct AnchorClock: Sendable {
    public static let toleranceMS: Int64 = 250

    private var last: CaptureAnchor?

    public init() {}

    public mutating func anchor(forBufferStartingAt sample: Int64, wallClockMS: Int64) -> CaptureAnchor? {
        if let last {
            let predicted = last.ms + CapturePCM.ms(forSamples: sample - last.sample)
            if abs(wallClockMS - predicted) <= Self.toleranceMS {
                return nil
            }
        }
        let anchor = CaptureAnchor(sample: sample, ms: wallClockMS)
        last = anchor
        return anchor
    }

    /// 書き込み先を開いた時に呼ぶ。次のbufferで必ずanchorを返す
    public mutating func reset() {
        last = nil
    }
}
```

`Sources/NotetakeCore/Capture/CaptureSessionInfo.swift`:

```swift
import Foundation

/// 生音声ディレクトリの`session.json`。serveが収録の開始時に書き、確定処理が出力先とMacの情報を知るために読む
public struct CaptureSessionInfo: Codable, Equatable, Sendable {
    public var outputDirectory: String
    public var device: String
    public var deviceName: String
    public var owner: String

    enum CodingKeys: String, CodingKey {
        case outputDirectory = "output_directory"
        case device
        case deviceName = "device_name"
        case owner
    }

    public init(outputDirectory: String, device: String, deviceName: String, owner: String) {
        self.outputDirectory = outputDirectory
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
    }
}
```

`Sources/NotetakeCore/Capture/CaptureSessionPaths.swift`の`checkpointFileURL`の後に足す:

```swift
    public static func pcmURL(sessionDirectory: URL, source: Source) -> URL {
        sessionDirectory.appendingPathComponent("\(source.rawValue).pcm")
    }

    public static func metaURL(sessionDirectory: URL, source: Source) -> URL {
        sessionDirectory.appendingPathComponent("\(source.rawValue).meta.jsonl")
    }

    public static func sessionInfoURL(sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("session.json")
    }
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'pcmConverts|pcmEncodes|metaLines|timeline|anchorClock|sessionInfo'`
Expected: PASS（10件）

- [ ] **Step 5: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/NotetakeCore/Capture/CapturePCM.swift Sources/NotetakeCore/Capture/CaptureMeta.swift Sources/NotetakeCore/Capture/CaptureTimeline.swift Sources/NotetakeCore/Capture/CaptureSessionInfo.swift Sources/NotetakeCore/Capture/CaptureSessionPaths.swift Tests/NotetakeCoreTests/CaptureFormatTests.swift
git commit -m "$(cat <<'MSG'
feat(core): define the raw audio format with wall-clock anchors

Raw audio becomes headerless 16 kHz mono Float32, so a byte offset maps
straight to a sample number. A meta.jsonl beside it records anchors that
tie sample numbers to wall-clock time, the input device in use, and
capture state changes. CaptureTimeline turns sample numbers back into
wall-clock time and devices, and AnchorClock tells the writer when a new
anchor is needed (more than 250 ms of drift or a gap).

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 3: 望む状態と実状態のファイル

serveとcapture-daemonの受け渡しを、命令とeventのファイルから、望む状態と実状態の2つのファイルへ置き換えるための型を作る。capture-daemonは再起動しても望む状態を読み直せば同じ収録へ追記を続けられ、古い命令を再生する問題は形の上で起きない。

**Files:**
- Create: `Sources/NotetakeCore/Capture/CaptureState.swift`
- Modify: `Sources/NotetakeCore/Capture/CaptureStatePaths.swift`（URLを2つ足す）、`Tests/NotetakeCoreTests/HeartbeatTests.swift`（`statePathsAreDistinct`）
- Test: `Tests/NotetakeCoreTests/CaptureStateTests.swift`

**Interfaces:**
- Consumes: `JSONFile`（Task 1）、`CaptureSourceState`（Task 2）
- Produces:
  - `struct CaptureDesiredState { struct Recording { var prefix: String; var directory: String }; var recording: Recording?; var sources: [Source]; var pinnedInputUID: String?; static let stopped }`。JSONのkeyは`recording`、`sources`、`pinned_input_uid`
  - `struct CaptureActualState { struct SourceStatus { var source: Source; var state: CaptureSourceState; var reason: String?; var input: InputDevice?; var fellBackFromPinned: Bool; var lastError: String? }; var pid: Int32; var prefix: String?; var sources: [SourceStatus]; var updated: Int64 }`。JSONのkeyは`fell_back_from_pinned`、`last_error`ほか
  - `struct DesiredStateWatcher(url:)`、`mutating poll() -> Change?`（`.changed(CaptureDesiredState)`か`.unreadable(String)`。更新時刻が変わらなければnil。ファイルが無い時だけ`.changed(.stopped)`。ほかのstat失敗は`.unreadable`で、同じ失敗は1度だけ返す）
  - `CaptureStatePaths.captureDesiredURL`（`capture-desired.json`）、`CaptureStatePaths.captureActualURL`（`capture-actual.json`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/CaptureStateTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func desiredStateUsesSnakeCaseKeys() throws {
    let desired = CaptureDesiredState(
        recording: .init(prefix: "2026-10-03_100000", directory: "/tmp/notetake-capture/2026-10-03_100000"),
        sources: [.mic, .system], pinnedInputUID: "external")
    let text = String(decoding: try JSONEncoder().encode(desired), as: UTF8.self)
    #expect(text.contains("\"pinned_input_uid\":\"external\""))
    #expect(try JSONDecoder().decode(CaptureDesiredState.self, from: Data(text.utf8)) == desired)
    #expect(
        try JSONDecoder().decode(CaptureDesiredState.self, from: Data(#"{"sources":[]}"#.utf8)) == .stopped)
}

@Test func actualStateUsesSnakeCaseKeys() throws {
    let actual = CaptureActualState(
        pid: 42, prefix: "p",
        sources: [
            .init(
                source: .mic, state: .recording,
                input: InputDevice(name: "内蔵マイク", uid: "builtin", spatial: false),
                fellBackFromPinned: true, lastError: "書けません")
        ],
        updated: 1)
    let text = String(decoding: try JSONEncoder().encode(actual), as: UTF8.self)
    #expect(text.contains("\"fell_back_from_pinned\":true"))
    #expect(text.contains("\"last_error\":\"書けません\""))
    #expect(try JSONDecoder().decode(CaptureActualState.self, from: Data(text.utf8)) == actual)
}

@Test func desiredStateWatcherReportsOnlyChanges() throws {
    let directory = temporaryDirectory("desired")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("capture-desired.json")
    var watcher = DesiredStateWatcher(url: url)

    #expect(watcher.poll() == .changed(.stopped))
    #expect(watcher.poll() == nil)

    let recording = CaptureDesiredState(
        recording: .init(prefix: "a", directory: "/tmp/a"), sources: [.mic], pinnedInputUID: nil)
    try JSONFile.write(recording, to: url)
    #expect(watcher.poll() == .changed(recording))
    #expect(watcher.poll() == nil)

    try AtomicFile.write(Data("not json".utf8), to: url)
    guard case .unreadable = watcher.poll() else {
        Issue.record("broken desired state must be reported as unreadable")
        return
    }

    try FileManager.default.removeItem(at: url)
    #expect(watcher.poll() == .changed(.stopped))
}

@Test func desiredStateWatcherReportsAnUnreadableFileOnceInsteadOfStopping() throws {
    let directory = temporaryDirectory("desired")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("capture-desired.json")
    var watcher = DesiredStateWatcher(url: url)
    #expect(watcher.poll() == .changed(.stopped))

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    guard case .unreadable = watcher.poll() else {
        Issue.record("a stat failure other than a missing file must not be read as stopped")
        return
    }
    #expect(watcher.poll() == nil)
}
```

`Tests/NotetakeCoreTests/HeartbeatTests.swift`の`statePathsAreDistinct`を置き換える:

```swift
@Test func statePathsAreDistinct() {
    let paths = [
        CaptureStatePaths.processHeartbeatURL,
        CaptureStatePaths.captureHeartbeatURL,
        CaptureStatePaths.captureCommandURL,
        CaptureStatePaths.captureEventURL,
        CaptureStatePaths.currentSessionMarkerURL,
        CaptureStatePaths.captureDesiredURL,
        CaptureStatePaths.captureActualURL,
    ]
    #expect(Set(paths.map(\.lastPathComponent)).count == paths.count)
    #expect(CaptureStatePaths.processHeartbeatURL.path.contains("Notetake/state"))
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'desiredState|actualState|statePaths'`
Expected: buildが`cannot find 'CaptureDesiredState' in scope`などで失敗する

- [ ] **Step 3: 実装する**

`Sources/NotetakeCore/Capture/CaptureState.swift`:

```swift
import Foundation

/// serveがcapture-daemonへ伝える望む状態（`capture-desired.json`）。収録中でなければ`recording`がnil
public struct CaptureDesiredState: Codable, Equatable, Sendable {
    public struct Recording: Codable, Equatable, Sendable {
        public var prefix: String
        /// 生音声ディレクトリの絶対path
        public var directory: String

        public init(prefix: String, directory: String) {
            self.prefix = prefix
            self.directory = directory
        }
    }

    public static let stopped = CaptureDesiredState(recording: nil, sources: [], pinnedInputUID: nil)

    public var recording: Recording?
    public var sources: [Source]
    /// micを固定する入力機器のUID。nilなら既定の入力を使う
    public var pinnedInputUID: String?

    enum CodingKeys: String, CodingKey {
        case recording
        case sources
        case pinnedInputUID = "pinned_input_uid"
    }

    public init(recording: Recording?, sources: [Source], pinnedInputUID: String?) {
        self.recording = recording
        self.sources = sources
        self.pinnedInputUID = pinnedInputUID
    }
}

/// capture-daemonが1秒ごとに書く実状態（`capture-actual.json`）。ファイルの更新時刻がcapture-daemonの心拍を兼ねる
public struct CaptureActualState: Codable, Equatable, Sendable {
    public struct SourceStatus: Codable, Equatable, Sendable {
        public var source: Source
        public var state: CaptureSourceState
        /// `retrying`の理由
        public var reason: String?
        public var input: InputDevice?
        /// 固定した入力機器が外れ、既定の入力で取り込んでいる
        public var fellBackFromPinned: Bool
        /// 最後に起きた書き込みや変換の失敗
        public var lastError: String?

        enum CodingKeys: String, CodingKey {
            case source
            case state
            case reason
            case input
            case fellBackFromPinned = "fell_back_from_pinned"
            case lastError = "last_error"
        }

        public init(
            source: Source, state: CaptureSourceState, reason: String? = nil, input: InputDevice? = nil,
            fellBackFromPinned: Bool = false, lastError: String? = nil
        ) {
            self.source = source
            self.state = state
            self.reason = reason
            self.input = input
            self.fellBackFromPinned = fellBackFromPinned
            self.lastError = lastError
        }
    }

    public var pid: Int32
    /// いま書いている収録。止まっていればnil
    public var prefix: String?
    public var sources: [SourceStatus]
    /// 書いた時刻（epoch ms）
    public var updated: Int64

    public init(pid: Int32, prefix: String?, sources: [SourceStatus], updated: Int64) {
        self.pid = pid
        self.prefix = prefix
        self.sources = sources
        self.updated = updated
    }
}

/// capture-daemonが望む状態のファイルを見張る。更新時刻が変わった時だけ読み直す
public struct DesiredStateWatcher: Sendable {
    public enum Change: Equatable, Sendable {
        case changed(CaptureDesiredState)
        /// 中身を解釈できない。capture-daemonは今の取り込みを変えずに続ける
        case unreadable(String)
    }

    private let url: URL
    private var checked = false
    private var lastModified: Date?
    private var lastStatFailure: String?

    public init(url: URL) {
        self.url = url
    }

    /// 最初の呼び出しと、前回から更新時刻が変わった時だけ値を返す。ファイルが無いのは停止中として扱う。
    /// 更新時刻を取れない他の失敗は停止とせず、`unreadable`として同じ失敗を1度だけ返す
    public mutating func poll() -> Change? {
        let modified: Date?
        do {
            modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            lastStatFailure = nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            modified = nil
            lastStatFailure = nil
        } catch {
            // 説明文には毎回変わる値が入るため、同じ失敗かどうかはdomainとcodeで見分ける
            let kind = "\((error as NSError).domain) \((error as NSError).code)"
            guard kind != lastStatFailure else { return nil }
            lastStatFailure = kind
            return .unreadable("\(error)")
        }
        if checked, modified == lastModified {
            return nil
        }
        checked = true
        lastModified = modified
        guard modified != nil else {
            return .changed(.stopped)
        }
        do {
            return .changed(try JSONFile.read(CaptureDesiredState.self, from: url) ?? .stopped)
        } catch {
            return .unreadable("\(error)")
        }
    }
}
```

`Sources/NotetakeCore/Capture/CaptureStatePaths.swift`の`currentSessionMarkerURL`の後に足す:

```swift
    public static var captureDesiredURL: URL { stateDirectory().appendingPathComponent("capture-desired.json") }
    public static var captureActualURL: URL { stateDirectory().appendingPathComponent("capture-actual.json") }
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'desiredState|actualState|statePaths'`
Expected: PASS

- [ ] **Step 5: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/NotetakeCore/Capture/CaptureState.swift Sources/NotetakeCore/Capture/CaptureStatePaths.swift Tests/NotetakeCoreTests/CaptureStateTests.swift Tests/NotetakeCoreTests/HeartbeatTests.swift
git commit -m "$(cat <<'MSG'
feat(core): add desired and actual capture state files

serve will describe the recording it wants in capture-desired.json, and
capture-daemon will report what it is doing in capture-actual.json every
second, its modification time doubling as the heartbeat. A missing
desired file means stopped; an unreadable one is reported so the daemon
keeps its current capture instead of stopping a recording.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 4: 生音声の書き手（SourceRecorder）

音声のcallbackは、bufferを写して直列のqueueへ渡すだけにする。16kHz monoへの変換、anchorの判定、`.pcm`と`.meta.jsonl`への書き込みは、そのqueueで行う。入力機器のformatの変化を扱うのは、ここの変換器だけにする。

anchorの位置に注意する。変換器（AVAudioConverter）は、先のsampleを使って計算するため、出力を遅らせて出す（48kHzから16kHzでは約1,100 sample、約70ms）。bufferの先頭が実際に入るsample番号は「書き込み済みのsample数 + 変換器がまだ出していないsample数（`pendingSamples`）」である。書き込み済みのsample数にanchorを付けると、途切れの直前の音が途切れの後の時刻になる。

同じ収録を開き直した時（capture-daemonの再起動）は末尾へ追記する。前のprocessが書きかけで落ちた端数byteを切り詰め、改行の無い最後の行を閉じてから書く。

書き込みの失敗は実状態の`lastError`に入れる。`lastError`は開いている収録の失敗だけを表すよう、収録を開く時に空に戻す。serveは収録ごとに実状態の見張りを作り直すため、空に戻さないと、前の収録で起きて直った失敗を、区切るたびに新しい失敗として送り直す。

書き込み先を開けなかった時（容量不足や一時的に書けない場合）は、次に届いたbufferで、1秒に1回まで開き直す。開き直せたら、開けなかったことを表す`lastError`は空に戻す。

取り込みの側が音声を捨てた時は、`CaptureSink.noteError`で`lastError`へ残す。長さ0のbufferは書く音声が無いだけなので、黙って捨てる。同じ状態（状態と理由が同じ）は`.meta.jsonl`へ続けて書かない。接続の失敗が5秒ごとに続いても、行が増え続けないようにするため。

sampleを`.pcm`へ書いてから、そのanchorとdeviceの行を`.meta.jsonl`へ書く。間で落ちても、書いていないsampleを指すanchorが残って、再起動後の時刻を誤らせることが無い。`.pcm`への書き込みが失敗したら、書いた分まで切り詰める。端数が残ると、以後のsample番号がファイルの位置とずれるため。

テストは、`.pcm`のsample数をファイルの大きさから数える（`PCMTailReader`はTask 8で作る）。

**Files:**
- Create: `Sources/notetaked/Capture/MonoResampler.swift`、`Sources/notetaked/Capture/SourceRecorder.swift`
- Test: `Tests/notetakedTests/SourceRecorderTests.swift`

**Interfaces:**
- Consumes: `CapturePCM`、`CaptureMetaLine`、`CaptureAnchor`、`AnchorClock`、`CaptureSessionPaths.pcmURL/metaURL`（Task 2）、`CaptureActualState.SourceStatus`、`CaptureSourceState`（Task 3）
- Produces:
  - `protocol CaptureSink: AnyObject, Sendable { func ingest(_ buffer: AVAudioPCMBuffer); func noteState(_ state: CaptureSourceState, reason: String?); func noteInput(_ device: InputDevice, fellBackFromPinned: Bool); func noteError(_ message: String) }`
  - `final class SourceRecorder: CaptureSink`: `init(source: Source, now: @escaping @Sendable () -> Date = { Date() })`、`open(directory: URL)`（書き込み先を切り替える。これより前に受け取ったbufferは前の収録へ書く。`lastError`を空に戻す。開けなければ、以後のbufferで1秒ごとに開き直す）、`close()`（変換器の残りを書いて閉じ、状態を`off`にする）、`snapshot() -> CaptureActualState.SourceStatus`
  - `struct CapturedChunk`（`init?(buffer:receivedAt:)`、`init(sampleRate:channelCount:interleaved:samples:receivedAt:)`）、`final class MonoResampler`（`convert(_:) throws -> [Float]`、`flush() throws -> [Float]`、`pendingSamples: Int`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/notetakedTests/SourceRecorderTests.swift`:

```swift
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
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'resampler|recorder'`
Expected: buildが`cannot find 'SourceRecorder' in scope`などで失敗する

- [ ] **Step 3: 実装する**

`Sources/notetaked/Capture/MonoResampler.swift`:

```swift
import AVFoundation
import Foundation
import NotetakeCore

enum MonoResamplerError: Error {
    case unsupportedSampleRate(Double)
    case bufferUnavailable
    case conversionFailed
}

/// 音声のcallbackで受け取ったbufferの写し。変換と書き込みをcallbackの外で行うため、記録用のqueueへ渡す
struct CapturedChunk: Sendable {
    let sampleRate: Double
    let channelCount: Int
    /// trueならframeごとにchannelが並び、falseならchannelごとのsample列を順に連結している
    let interleaved: Bool
    let samples: [Float]
    let receivedAt: Date

    var frameCount: Int { samples.count / channelCount }

    init(sampleRate: Double, channelCount: Int, interleaved: Bool, samples: [Float], receivedAt: Date) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.interleaved = interleaved
        self.samples = samples
        self.receivedAt = receivedAt
    }

    /// Float32でないformatと空のbufferはnil
    init?(buffer: AVAudioPCMBuffer, receivedAt: Date) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return nil }
        let interleaved = buffer.format.isInterleaved
        var copied: [Float] = []
        copied.reserveCapacity(frames * channels)
        if interleaved {
            copied.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames * channels))
        } else {
            for channel in 0..<channels {
                copied.append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames))
            }
        }
        self.init(
            sampleRate: buffer.format.sampleRate, channelCount: channels, interleaved: interleaved,
            samples: copied, receivedAt: receivedAt)
    }

    /// channelの平均をとってmonoにする
    func mono() -> [Float] {
        guard channelCount > 1 else { return samples }
        let frames = frameCount
        let scale = 1 / Float(channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved ? samples[frame * channelCount + channel] : samples[channel * frames + frame]
            }
            mono[frame] = sum * scale
        }
        return mono
    }
}

/// 入力機器のsample rateのmono音声を、生音声の16kHzへ変換する。
/// AVAudioConverterの状態をbufferをまたいで保つため、bufferの境目で音が欠けたりsample数がずれたりしない。
/// sample rateが変わった時だけ、それまでの残りを出し切ってから変換器を作り直す
final class MonoResampler {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    /// 今の変換器へ渡した音声の長さ（16kHzのsample数）
    private var consumed: Double = 0
    /// 今の変換器が出したsampleの数
    private var produced = 0

    /// 受け取った音声のうち、変換器がまだ出していないsampleの数。変換器は先のsampleを使って
    /// 計算するため、出力はbuffer1つ分ほど遅れて出てくる。次のbufferの先頭は、出力済みの数にこれを足した位置に入る
    var pendingSamples: Int { Int(consumed.rounded()) - produced }

    init() {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(CapturePCM.sampleRate), channels: 1,
                interleaved: false)
        else {
            preconditionFailure("16kHz mono Float32 is always a valid format")
        }
        outputFormat = format
    }

    func convert(_ chunk: CapturedChunk) throws -> [Float] {
        var output: [Float] = []
        if let converter, converter.inputFormat.sampleRate != chunk.sampleRate {
            output += try finish(converter)
        }
        let mono = chunk.mono()
        if chunk.sampleRate == outputFormat.sampleRate {
            return output + mono
        }
        let converter = try self.converter ?? makeConverter(sampleRate: chunk.sampleRate)
        self.converter = converter
        let converted = try drain(
            converter, input: try makeBuffer(mono, format: converter.inputFormat), endOfStream: false)
        consumed += Double(mono.count) * outputFormat.sampleRate / chunk.sampleRate
        produced += converted.count
        return output + converted
    }

    /// 変換器に残っているsampleを出し切る。書き込み先を切り替える時と止める時に呼ぶ
    func flush() throws -> [Float] {
        guard let converter else { return [] }
        return try finish(converter)
    }

    private func finish(_ converter: AVAudioConverter) throws -> [Float] {
        self.converter = nil
        consumed = 0
        produced = 0
        return try drain(converter, input: nil, endOfStream: true)
    }

    private func makeConverter(sampleRate: Double) throws -> AVAudioConverter {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw MonoResamplerError.unsupportedSampleRate(sampleRate)
        }
        return converter
    }

    private func makeBuffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw MonoResamplerError.bufferUnavailable
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// `input`を1度だけ渡し、変換器が出せる分を出し切るまでconvertを繰り返す
    private func drain(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> [Float] {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input?.frameLength ?? 0) * ratio).rounded(.up)) + 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw MonoResamplerError.bufferUnavailable
        }
        var collected: [Float] = []
        // convertは渡したblockを同じ呼び出しの中で同期的に呼ぶため、`supplied`を並行に触ることはない
        nonisolated(unsafe) var supplied = false
        while true {
            buffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let conversionError {
                throw conversionError
            }
            if buffer.frameLength > 0, let data = buffer.floatChannelData {
                collected.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            switch status {
            case .haveData:
                if buffer.frameLength == 0 { return collected }
            case .inputRanDry, .endOfStream:
                return collected
            case .error:
                throw MonoResamplerError.conversionFailed
            @unknown default:
                return collected
            }
        }
    }
}
```

`Sources/notetaked/Capture/SourceRecorder.swift`:

```swift
import AVFoundation
import Foundation
import NotetakeCore

/// 取り込み（MicCaptureとSystemAudioCapture）が、音声と状態の変化を渡す先
protocol CaptureSink: AnyObject, Sendable {
    /// 音声のcallbackから呼ぶ。bufferの写しを取るだけで、変換と書き込みは記録用のqueueで行う
    func ingest(_ buffer: AVAudioPCMBuffer)
    func noteState(_ state: CaptureSourceState, reason: String?)
    func noteInput(_ device: InputDevice, fellBackFromPinned: Bool)
    /// 取り込みの途中で音声を失った失敗を、実状態の`lastError`へ残す
    func noteError(_ message: String)
}

/// 1つのsourceの生音声を書く。callbackから受け取ったbufferを直列のqueueへ渡し、
/// 16kHz monoへの変換、anchorの判定、`.pcm`と`.meta.jsonl`への書き込みをそのqueueで行う
final class SourceRecorder: CaptureSink, @unchecked Sendable {
    // @unchecked Sendable: 可変の状態はすべて`queue`の上でだけ読み書きする
    let source: Source
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    private let resampler = MonoResampler()
    private var anchorClock = AnchorClock()
    /// 書き込み先の収録。開けなかった時に開き直すため覚えておく
    private var directory: URL?
    private var lastOpenAttempt: Date?
    private var pcm: FileHandle?
    private var meta: FileHandle?
    private var writtenSamples: Int64 = 0
    private var input: InputDevice?
    private var deviceLinePending = false
    /// いまの`.meta.jsonl`へ最後に書いた状態。再試行のたびに同じ行を足さないために使う
    private var lastStateLine: StateLine?
    private var status: CaptureActualState.SourceStatus

    private static let openFailurePrefix = "書き込み先を開けません"

    private struct StateLine: Equatable {
        let state: CaptureSourceState
        let reason: String?
    }

    init(source: Source, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.now = now
        queue = DispatchQueue(label: "io.github.bash0c7.notetaked.recorder.\(source.rawValue)")
        status = CaptureActualState.SourceStatus(source: source, state: .off)
    }

    // MARK: - CaptureSink

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let receivedAt = now()
        guard let chunk = CapturedChunk(buffer: buffer, receivedAt: receivedAt) else {
            let description = "\(buffer.format)"
            queue.async { self.recordError("Float32でない音声は書けません: \(description)") }
            return
        }
        queue.async { self.write(chunk) }
    }

    func noteState(_ state: CaptureSourceState, reason: String?) {
        let at = now()
        queue.async {
            self.status.state = state
            self.status.reason = state == .retrying ? reason : nil
            let line = StateLine(state: state, reason: reason)
            guard line != self.lastStateLine else { return }
            self.lastStateLine = line
            self.appendMeta(.state(sample: self.writtenSamples, ms: Self.ms(at), state: state, reason: reason))
        }
    }

    func noteInput(_ device: InputDevice, fellBackFromPinned: Bool) {
        queue.async {
            self.input = device
            self.deviceLinePending = true
            self.status.input = device
            self.status.fellBackFromPinned = fellBackFromPinned
        }
    }

    func noteError(_ message: String) {
        queue.async { self.recordError(message) }
    }

    // MARK: - control

    /// 書き込み先を`directory`の収録へ切り替える。これより前に受け取ったbufferは前の収録へ、
    /// 後に受け取ったbufferは新しい収録へ書く。同じ収録を開き直した時は末尾へ追記する。
    /// `lastError`は開いた収録の失敗だけを表すよう空に戻してから、前の収録を閉じる
    func open(directory: URL) {
        queue.sync {
            status.lastError = nil
            closeFiles()
            self.directory = directory
            openFiles(at: now())
        }
    }

    /// 変換器に残った音声を書き出してファイルを閉じる。取り込みを止めた後に呼ぶ
    func close() {
        queue.sync {
            closeFiles()
            directory = nil
            status.state = .off
            status.reason = nil
        }
    }

    func snapshot() -> CaptureActualState.SourceStatus {
        queue.sync { status }
    }

    // MARK: - queue

    private func openFiles(at attemptTime: Date) {
        guard let directory else { return }
        lastOpenAttempt = attemptTime
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pcm = try Self.openForAppend(CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: source))
            let meta = try Self.openForAppend(CaptureSessionPaths.metaURL(sessionDirectory: directory, source: source))
            // 前のprocessが書きかけで終わっていても、追記がsampleと行の境目から始まるようにする
            let pcmEnd = try pcm.seekToEnd()
            let alignedEnd = pcmEnd - pcmEnd % UInt64(CapturePCM.bytesPerSample)
            if alignedEnd != pcmEnd {
                try pcm.truncate(atOffset: alignedEnd)
            }
            try Self.terminateLastLine(meta)
            self.pcm = pcm
            self.meta = meta
            writtenSamples = Int64(alignedEnd) / Int64(CapturePCM.bytesPerSample)
            anchorClock.reset()
            deviceLinePending = input != nil
            lastStateLine = nil
            if status.lastError?.hasPrefix(Self.openFailurePrefix) == true {
                status.lastError = nil
            }
        } catch {
            recordError("\(Self.openFailurePrefix): \(error)")
        }
    }

    private func write(_ chunk: CapturedChunk) {
        if pcm == nil || meta == nil {
            // 開けなかった書き込み先は、空きができた時などに書けるよう、1秒ごとに開き直す
            guard let lastOpenAttempt, chunk.receivedAt.timeIntervalSince(lastOpenAttempt) >= 1 else { return }
            openFiles(at: chunk.receivedAt)
        }
        guard let pcm, meta != nil else { return }
        let firstSample = writtenSamples + Int64(resampler.pendingSamples)
        let samples: [Float]
        do {
            samples = try resampler.convert(chunk)
        } catch {
            recordError("16kHzへ変換できません: \(error)")
            return
        }
        guard !samples.isEmpty else { return }
        let durationMS = Int64((Double(chunk.frameCount) / chunk.sampleRate * 1000).rounded())
        let startMS = Self.ms(chunk.receivedAt) - durationMS
        let anchor = anchorClock.anchor(forBufferStartingAt: firstSample, wallClockMS: startMS)
        do {
            try pcm.write(contentsOf: CapturePCM.encode(samples))
        } catch {
            recordError("生音声を書けません: \(error)")
            // 書きかけの端数を残すと、以後のsample番号がファイルの位置とずれる
            do {
                try pcm.truncate(atOffset: UInt64(writtenSamples) * UInt64(CapturePCM.bytesPerSample))
            } catch {
                recordError("書きかけの生音声を切り詰められません: \(error)")
            }
            // 書けなかった区間の後は、次に書けたbufferにanchorを付ける
            anchorClock.reset()
            return
        }
        writtenSamples += Int64(samples.count)
        // sampleを書いてから、そのanchorとdeviceの行を書く。間で落ちても、書いていないsampleを指すanchorが残って
        // 再起動後の時刻を誤らせることが無い
        if let anchor {
            appendMeta(.anchor(anchor))
        }
        if deviceLinePending, let input {
            appendMeta(.device(sample: firstSample, device: input))
            deviceLinePending = false
        }
    }

    private func closeFiles() {
        if let pcm {
            do {
                let tail = try resampler.flush()
                if !tail.isEmpty {
                    try pcm.write(contentsOf: CapturePCM.encode(tail))
                    writtenSamples += Int64(tail.count)
                }
            } catch {
                recordError("最後の音声を書けません: \(error)")
            }
        }
        for handle in [pcm, meta].compactMap({ $0 }) {
            do {
                try handle.close()
            } catch {
                recordError("ファイルを閉じられません: \(error)")
            }
        }
        pcm = nil
        meta = nil
    }

    private func appendMeta(_ line: CaptureMetaLine) {
        guard let meta else { return }
        do {
            try meta.write(contentsOf: Data((try line.encodedLine() + "\n").utf8))
        } catch {
            recordError("時刻情報を書けません: \(error)")
        }
    }

    /// 失敗を実状態の`lastError`に残す。直前と同じ失敗は`.meta.jsonl`へ書き直さない
    private func recordError(_ message: String) {
        guard status.lastError != message else { return }
        status.lastError = message
        guard let meta else { return }
        let line = CaptureMetaLine.state(sample: writtenSamples, ms: Self.ms(now()), state: status.state, reason: message)
        // この行を書けなくても、失敗は`lastError`で実状態に出る
        if let text = try? line.encodedLine() {
            try? meta.write(contentsOf: Data((text + "\n").utf8))
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func openForAppend(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path),
            !FileManager.default.createFile(atPath: url.path, contents: nil)
        {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try FileHandle(forUpdating: url)
    }

    /// 最後の行が改行で終わっていなければ改行を足す
    private static func terminateLastLine(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        let last = try handle.read(upToCount: 1)
        _ = try handle.seekToEnd()
        if last != Data([0x0A]) {
            try handle.write(contentsOf: Data([0x0A]))
        }
    }
}
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'resampler|recorder'`
Expected: PASS（14件）

- [ ] **Step 5: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/notetaked/Capture/MonoResampler.swift Sources/notetaked/Capture/SourceRecorder.swift Tests/notetakedTests/SourceRecorderTests.swift
git commit -m "$(cat <<'MSG'
feat(capture): write raw audio from a per-source recorder queue

The audio callback only copies the buffer and hands it to a serial
queue, where the recorder downmixes, resamples to 16 kHz with a
streaming converter, decides anchors and appends to <source>.pcm and
<source>.meta.jsonl. Anchors sit where the buffer's first sample lands,
which is ahead of the samples already written because the converter
holds back its output. Reopening a recording after a crash continues at
sample and line boundaries, and switching directories at a buffer
boundary loses no audio.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 5: capture-daemonを望む状態で動かし、止まった取り込みを再開する

capture-daemonの本体を`CaptureController`にする。200msごとに望む状態のファイルを見て、取り込みと書き込み先を合わせ、1秒ごとに実状態を書く。prefixだけが変わった時（区切り）は、取り込みを止めずに書き込み先だけを切り替える。

取り込みは新しいprotocol`SourceCapture`に合わせる。開始の失敗や途中の停止は投げずに`CaptureSink.noteState`で伝え、自分で再開を試みる。

- **system**: ScreenCaptureKitはディスプレイの消灯などでstreamを自ら止める。停止を`SCStreamDelegate.stream(_:didStopWithError:)`で受け取り、`retrying`を伝え、5秒ごとに`SCShareableContent`の取得からstreamを作り直す。`start`はすぐ`retrying`（接続しています）を伝えて返し、接続はTaskで行う（`SCShareableContent`の取得を待つ間も、capture-daemonが実状態を書き続けられるようにするため）。停止の知らせが無いまま音声のbufferが届かなくなる場合に備え、10秒届かなければstreamを作り直す（ScreenCaptureKitは無音の間もbufferを届けるため、届かないことは異常を表す）。最後に届いた時刻は`OSAllocatedUnfairLock`で持ち、5秒ごとに確かめる。sample bufferを包めなかった時は`noteError`で伝える（長さ0のbufferは除く）。作ったばかりで不要になったstreamを止められなかった時は、stderrへ残す。止めた後に遅れて届く停止の知らせは、streamを作るたびに進める番号（`generation`）で無視する。映像の出力も登録して捨てる（登録しないとScreenCaptureKitが毎秒error logを出す）。音声のformatはsample bufferのformat descriptionから作る
- **mic**: AVAudioEngineは既定の入力が変わると自ら止まるため、構成変更の通知でtapを張り直す。`engine.start()`の失敗を捨てず、1・2・4・8・16秒、以後30秒の間隔で再試行する。固定した機器が外れたら既定の入力へ戻し、`noteInput(_, fellBackFromPinned: true)`で伝える。接続中なのに固定した機器を開けなかった時も、固定は残したまま既定の入力で取り込み、`noteError`で「固定した入力機器を開けないため、既定の入力で取り込みます」と伝える。AUHALのrender callbackがbufferを確保できない、または`AudioUnitRender`が失敗した時も、失敗が変わるたびに`noteError`で伝える。固定した機器はAUHAL（Technical Note TN2091の手順）で取り込む。AVAudioEngineの入力に機器を直接設定すると、formatが追従せずcrashや無音になるため
- `installTap`のclosureには必ず`@Sendable`を付ける。`AVAudioNodeTapBlock`は`@Sendable`ではないため、付けないとactorに隔離されたclosureと推論され、audioのthreadから呼ばれた時に実行時の隔離検査で止まる
- capture-daemonは、状態ディレクトリの`capture-daemon.lock`に排他lock（`flock`）を取り、取れなければ終わる。2つのcapture-daemonが同じ生音声へ書かないようにするため。lockはprocessの終了で離れる
- 実状態を書く1秒の間隔は、単調な時計（`ContinuousClock`）で測る。壁時計が巻き戻っても、書き込みが止まらないようにするため
- `DesiredStateWatcher`は、望む状態のファイルが無い時だけ停止として扱う。更新時刻を取れない他の失敗（権限など）は`unreadable`として、いまの取り込みを続ける
- capture-daemonは、起動したprocess（appかscript）が終わったら、取り込みを止めて終える。繰り返しのたびに`getppid()`を起動時の値と比べる。appがcrashや強制終了で消えた後も動き続けると、起動し直したappが2つ目のcapture-daemonを起動し、2つが同じ`.pcm`と`.meta.jsonl`へ追記して生音声が壊れるため。SIGTERMの時と同じ`shutdown`で止める

serve側の古い読み手（`RawAudioReaderCapture`）は`AudioCapture`protocolのまま、Task 12で消す。`capture`subcommandは、取り込みを古いprotocolで使っていたため、ここで消す（specの「使われていないもの」にも入っている）。capture-daemonは`capture.heartbeat`を書かなくなるため、appの`CaptureDaemonSupervisor`は実状態のファイルの更新時刻で生存を判断する。

**Files:**
- Create: `Sources/NotetakeCore/Capture/RetryBackoff.swift`、`Sources/NotetakeCore/Capture/InstanceLock.swift`、`Sources/notetaked/Capture/CaptureController.swift`
- Replace: `Sources/notetaked/Audio/SystemAudioCapture.swift`、`Sources/notetaked/Audio/MicCapture.swift`、`Sources/notetaked/Commands/CaptureDaemonCommand.swift`
- Modify: `Sources/notetaked/Notetaked.swift`、`Sources/NotetakeCore/Capture/CaptureStatePaths.swift`、`Apps/Notetake/CaptureDaemonSupervisor.swift`、`Tests/NotetakeCoreTests/HeartbeatTests.swift`
- Delete: `Sources/notetaked/Capture/CaptureSessionRunner.swift`、`Sources/notetaked/Commands/CaptureCommand.swift`
- Test: `Tests/NotetakeCoreTests/RetryBackoffTests.swift`、`Tests/NotetakeCoreTests/InstanceLockTests.swift`、`Tests/notetakedTests/CaptureControllerTests.swift`

**Interfaces:**
- Consumes: `SourceRecorder`、`CaptureSink`（Task 4）、`CaptureDesiredState`、`CaptureActualState`、`DesiredStateWatcher`、`CaptureStatePaths.captureDesiredURL/captureActualURL`（Task 3）、`JSONFile`（Task 1）
- Produces:
  - `protocol SourceCapture: AnyObject, Sendable { func start(into sink: any CaptureSink) async; func stop() async }`
  - `actor CaptureController`: `init(makeCapture: @escaping CaptureFactory)`（`CaptureFactory = @Sendable (Source, String?) -> any SourceCapture`）、`apply(_ desired: CaptureDesiredState) async`、`stopAll() async`、`actualState(pid: Int32, now: Date) -> CaptureActualState`
  - `actor SystemAudioCapture: SourceCapture`（`init()`）、`actor MicCapture: SourceCapture`（`init(pinnedUID: String?)`）
  - `RetryBackoff.seconds(afterFailures: Int) -> Int`
  - `InstanceLock.acquire(at: URL) throws -> InstanceLock?`（別に持つものがあればnil。解放で離れる）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/RetryBackoffTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func retryBackoffDoublesUpToThirtySeconds() {
    #expect((0..<8).map { RetryBackoff.seconds(afterFailures: $0) } == [1, 2, 4, 8, 16, 30, 30, 30])
}
```

`Tests/NotetakeCoreTests/InstanceLockTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

@Test func instanceLockIsExclusiveUntilReleased() throws {
    let url = temporaryDirectory("lock").appendingPathComponent("capture-daemon.lock")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var first = try InstanceLock.acquire(at: url)
    #expect(first != nil)
    #expect(try InstanceLock.acquire(at: url) == nil)
    first = nil
    #expect(try InstanceLock.acquire(at: url) != nil)
}
```

`Tests/notetakedTests/CaptureControllerTests.swift`（`.pcm`のsample数はファイルの大きさから数える）:

```swift
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
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'retryBackoff|instanceLock|controller'`
Expected: buildが`cannot find 'RetryBackoff' in scope`、`cannot find 'InstanceLock' in scope`、`cannot find type 'SourceCapture' in scope`などで失敗する

- [ ] **Step 3: 再試行の間隔と制御を実装する**

`Sources/NotetakeCore/Capture/RetryBackoff.swift`:

```swift
/// 取り込みの再試行の間隔。1秒から倍にしていき、30秒で頭打ちにする
public enum RetryBackoff {
    public static let maxSeconds = 30

    public static func seconds(afterFailures failures: Int) -> Int {
        guard failures < 5 else { return maxSeconds }
        return min(1 << failures, maxSeconds)
    }
}
```

`Sources/NotetakeCore/Capture/InstanceLock.swift`:

```swift
import Foundation

/// processに1つだけ持てる排他lock。capture-daemonが2つ同時に同じ生音声へ書かないために使う。
/// lockはprocessの終了（crashやSIGKILLを含む）で自動的に離れる
public final class InstanceLock: @unchecked Sendable {
    // @unchecked Sendable: 開いたfile descriptorだけを持ち、lockの確認は初期化の中で終わる
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// `url`のfileに排他lockを取る。別のprocessか別のInstanceLockが持っていればnilを返す
    public static func acquire(at url: URL) throws -> InstanceLock? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
        return InstanceLock(descriptor: descriptor)
    }
}
```

`Sources/notetaked/Capture/CaptureController.swift`:

```swift
import Foundation
import NotetakeCore

/// micかsystemの音声を取り込み、`CaptureSink`へ渡す。開始の失敗や途中の停止は投げずに
/// `noteState`で伝え、自分で再開を試みる
protocol SourceCapture: AnyObject, Sendable {
    func start(into sink: any CaptureSink) async
    func stop() async
}

/// capture-daemonの本体。望む状態に合わせて取り込みと書き込み先を揃え、実状態を返す。
/// 区切り（prefixだけが変わる）では取り込みを止めず、書き込み先だけを切り替える
actor CaptureController {
    typealias CaptureFactory = @Sendable (_ source: Source, _ pinnedInputUID: String?) -> any SourceCapture

    private struct Running {
        let recorder: SourceRecorder
        let capture: any SourceCapture
        let pinnedInputUID: String?
    }

    private let makeCapture: CaptureFactory
    private var running: [Source: Running] = [:]
    private var prefix: String?

    init(makeCapture: @escaping CaptureFactory) {
        self.makeCapture = makeCapture
    }

    func apply(_ desired: CaptureDesiredState) async {
        guard let recording = desired.recording else {
            await stopAll()
            return
        }
        let directory = URL(fileURLWithPath: recording.directory)
        let wanted = desired.sources.filter { $0 == .mic || $0 == .system }
        for source in Array(running.keys) where !wanted.contains(source) {
            await stop(source)
        }
        if let mic = running[.mic], mic.pinnedInputUID != desired.pinnedInputUID {
            await stop(.mic)
        }
        for source in wanted {
            if let current = running[source] {
                if recording.prefix != prefix {
                    current.recorder.open(directory: directory)
                }
                continue
            }
            let pinnedInputUID = source == .mic ? desired.pinnedInputUID : nil
            let recorder = SourceRecorder(source: source)
            recorder.open(directory: directory)
            let capture = makeCapture(source, pinnedInputUID)
            running[source] = Running(recorder: recorder, capture: capture, pinnedInputUID: pinnedInputUID)
            await capture.start(into: recorder)
        }
        prefix = recording.prefix
    }

    func stopAll() async {
        for source in Array(running.keys) {
            await stop(source)
        }
        prefix = nil
    }

    func actualState(pid: Int32, now: Date) -> CaptureActualState {
        CaptureActualState(
            pid: pid, prefix: prefix,
            sources: [Source.mic, .system].compactMap { running[$0]?.recorder.snapshot() },
            updated: Int64((now.timeIntervalSince1970 * 1000).rounded()))
    }

    private func stop(_ source: Source) async {
        guard let entry = running.removeValue(forKey: source) else { return }
        await entry.capture.stop()
        entry.recorder.close()
    }
}
```

- [ ] **Step 4: 取り込みを置き換える**

`Sources/notetaked/Audio/SystemAudioCapture.swift`を次の内容で置き換える:

```swift
import AVFoundation
import CoreMedia
import Foundation
import NotetakeCore
import os
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: "取り込めるディスプレイがありません"
        }
    }
}

/// ScreenCaptureKitでsystem全体の音声（自process以外）を取り込む。
/// ScreenCaptureKitはディスプレイの消灯などでstreamを自ら止めるため、停止をdelegateで受け取り、
/// 5秒ごとにディスプレイの取得からstreamを作り直す。
/// 停止の知らせが無いまま音声のbufferが届かなくなった時のために、10秒届かなければstreamを作り直す
/// （ScreenCaptureKitは無音の間もbufferを届ける）
actor SystemAudioCapture: SourceCapture {
    private static let retryInterval: Duration = .seconds(5)
    private static let watchInterval: Duration = .seconds(5)
    private static let silenceLimit: Duration = .seconds(10)

    private var sink: (any CaptureSink)?
    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var retryTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// streamを作るたびと止めるたびに進める。古いstreamから遅れて届いた停止の知らせを無視するために使う
    private var generation = 0

    func start(into sink: any CaptureSink) async {
        self.sink = sink
        sink.noteState(.retrying, reason: "ScreenCaptureKitへ接続しています")
        scheduleConnect(after: nil)
    }

    func stop() async {
        sink = nil
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        watchTask?.cancel()
        watchTask = nil
        output = nil
        guard let stream else { return }
        self.stream = nil
        // 既にScreenCaptureKitが止めたstreamではerrorになるが、止めるという目的は果たしている
        try? await stream.stopCapture()
    }

    private func scheduleConnect(after delay: Duration?) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func connect() async {
        guard let sink else { return }
        generation += 1
        let attempt = generation
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw SystemAudioCaptureError.noDisplayAvailable
            }
            let output = SystemAudioOutput(sink: sink) { [weak self] error in
                Task { await self?.streamStopped(error, generation: attempt) }
            }
            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                configuration: Self.configuration(), delegate: output)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            // 映像の出力が無いとScreenCaptureKitが毎秒error logを出すため、受け取って捨てる
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            guard attempt == generation else {
                await stopAbandoned(stream)
                return
            }
            self.stream = stream
            self.output = output
            sink.noteState(.recording, reason: nil)
            watchForSilence(of: output, generation: attempt)
        } catch {
            guard attempt == generation else { return }
            sink.noteState(.retrying, reason: error.localizedDescription)
            scheduleConnect(after: Self.retryInterval)
        }
    }

    /// 開始を待つ間に不要になったstreamを止める。止められないとcapture indicatorが残るため、失敗を残す
    private func stopAbandoned(_ stream: SCStream) async {
        do {
            try await stream.stopCapture()
        } catch {
            FileHandle.standardError.write(
                Data("capture-daemon: 不要になったsystem音声のstreamを止められません: \(error)\n".utf8))
        }
    }

    private func watchForSilence(of output: SystemAudioOutput, generation watched: Int) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled else { return }
                if output.timeSinceLastAudio() >= Self.silenceLimit {
                    await self?.rebuildSilentStream(generation: watched)
                    return
                }
            }
        }
    }

    private func rebuildSilentStream(generation watched: Int) async {
        guard watched == generation, let sink, let stream else { return }
        generation += 1
        self.stream = nil
        output = nil
        sink.noteState(.retrying, reason: "音声が届かないため、ScreenCaptureKitへ接続し直します")
        await stopAbandoned(stream)
        scheduleConnect(after: nil)
    }

    private func streamStopped(_ error: any Error, generation stopped: Int) {
        guard stopped == generation, let sink else { return }
        watchTask?.cancel()
        watchTask = nil
        stream = nil
        output = nil
        sink.noteState(.retrying, reason: error.localizedDescription)
        scheduleConnect(after: Self.retryInterval)
    }

    private static func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        // 映像は捨てるため、最小の大きさと頻度にする
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        return configuration
    }
}

/// ScreenCaptureKitのcallbackを受ける。`SCStreamOutput`と`SCStreamDelegate`はNSObjectを要求するため、
/// actorの外に置く
private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked Sendable: 不変の参照だけを持ち、ScreenCaptureKitは`queue`の上で音声を渡す
    let queue = DispatchQueue(label: "io.github.bash0c7.notetaked.system-audio")
    private let sink: any CaptureSink
    private let onStop: @Sendable (any Error) -> Void
    private let lastAudio: OSAllocatedUnfairLock<ContinuousClock.Instant>

    init(sink: any CaptureSink, onStop: @escaping @Sendable (any Error) -> Void) {
        self.sink = sink
        self.onStop = onStop
        lastAudio = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    }

    /// 最後に音声のbufferが届いてからの時間。届く前は、streamを作ってからの時間
    func timeSinceLastAudio() -> Duration {
        ContinuousClock.now - lastAudio.withLock { $0 }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lastAudio.withLock { $0 = ContinuousClock.now }
        // 長さ0のbufferは書く音声が無いだけで、失敗ではない
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let buffer = Self.makeBuffer(from: sampleBuffer) else {
            sink.noteError("system音声のbufferを取り出せません")
            return
        }
        sink.ingest(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
    }

    /// audioのCMSampleBufferをAVAudioPCMBufferへ包む。sampleはCMBlockBufferが持つため写さず、
    /// その保持をAVAudioPCMBufferの解放まで延ばす
    private static func makeBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        var blockBuffer: CMBlockBuffer?
        var bufferListSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &bufferListSizeNeeded, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, bufferListSizeNeeded > 0 else { return nil }

        let rawListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawListPointer.deallocate() }
        let audioBufferListPointer = rawListPointer.assumingMemoryBound(to: AudioBufferList.self)

        blockBuffer = nil
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: audioBufferListPointer,
            bufferListSize: bufferListSizeNeeded, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let retainedBlockBuffer = blockBuffer else { return nil }

        return AVAudioPCMBuffer(
            pcmFormat: format, bufferListNoCopy: audioBufferListPointer,
            deallocator: { _ in _ = retainedBlockBuffer })
    }
}
```

`Sources/notetaked/Audio/MicCapture.swift`を次の内容で置き換える（`MicCapture.currentInputDevice()`は使われていないため無くなる）:

```swift
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import NotetakeCore

/// 既定の入力機器（AVAudioEngine）か、固定した入力機器（AUHAL）から音声を取り込む。
/// AVAudioEngineは既定の入力が変わると自ら止まるため、構成変更の通知でtapを張り直す。
/// `engine.start()`が失敗したら、1秒から倍にしていき最大30秒間隔で再試行する。
/// 固定した機器が外れたら既定の入力へ戻し、そのことを`noteInput`で伝える
actor MicCapture: SourceCapture {
    private let pinnedUID: String?
    private let engine = AVAudioEngine()
    private var sink: (any CaptureSink)?
    private var pinned: AUHALPinnedCapture?
    private var fellBack = false
    private var observers: [any NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var failures = 0

    init(pinnedUID: String?) {
        self.pinnedUID = pinnedUID
    }

    func start(into sink: any CaptureSink) async {
        self.sink = sink
        observeDevices()
        if startPinnedIfAvailable(sink) { return }
        startEngine()
    }

    func stop() async {
        sink = nil
        retryTask?.cancel()
        retryTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        pinned?.stop()
        pinned = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// 固定した機器が接続中ならAUHALで取り込む。AVAudioEngineの入力に機器を直接設定すると、
    /// formatが追従せずcrashや無音になるため、固定時はAVAudioEngineを使わない。
    /// 接続中なのに開けなかった時は、固定を残したまま既定の入力で取り込み、そのことを伝える
    private func startPinnedIfAvailable(_ sink: any CaptureSink) -> Bool {
        guard
            let pinnedUID,
            let device = InputDeviceProbe.all().first(where: { $0.uid == pinnedUID }),
            let deviceID = InputDeviceProbe.audioDeviceID(forUID: pinnedUID)
        else { return false }
        guard let capture = AUHALPinnedCapture(deviceID: deviceID) else {
            fallBackToDefaultInput(sink, detail: "設定できません")
            return false
        }
        do {
            try capture.start(into: sink)
        } catch {
            capture.stop()
            fallBackToDefaultInput(sink, detail: "\(error)")
            return false
        }
        pinned = capture
        sink.noteInput(device, fellBackFromPinned: false)
        sink.noteState(.recording, reason: nil)
        return true
    }

    private func fallBackToDefaultInput(_ sink: any CaptureSink, detail: String) {
        fellBack = true
        sink.noteError("固定した入力機器を開けないため、既定の入力で取り込みます: \(detail)")
    }

    private func startEngine() {
        guard let sink else { return }
        retryTask?.cancel()
        retryTask = nil
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("入力機器がありません")
            return
        }
        // AVAudioNodeTapBlockは@Sendableではないため、明示しないとactorに隔離されたclosureと推論され、
        // audioのthreadから呼ばれた時に実行時の隔離検査で止まる
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            sink.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail(error.localizedDescription)
            return
        }
        failures = 0
        sink.noteInput(InputDeviceProbe.current(), fellBackFromPinned: fellBack)
        sink.noteState(.recording, reason: nil)
    }

    private func fail(_ reason: String) {
        sink?.noteState(.retrying, reason: reason)
        let delay = Duration.seconds(RetryBackoff.seconds(afterFailures: failures))
        failures += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.restartEngine()
        }
    }

    private func restartEngine() {
        guard sink != nil, pinned == nil else { return }
        startEngine()
    }

    private func observeDevices() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
                [weak self] _ in
                Task { await self?.restartEngine() }
            })
        observers.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
                [weak self] notification in
                guard let uid = (notification.object as? AVCaptureDevice)?.uniqueID else { return }
                Task { await self?.deviceDisconnected(uid: uid) }
            })
    }

    private func deviceDisconnected(uid: String) {
        guard uid == pinnedUID, let pinned, let sink else { return }
        pinned.stop()
        self.pinned = nil
        fellBack = true
        sink.noteState(.retrying, reason: "固定した入力機器が外れたため、既定の入力へ切り替えます")
        startEngine()
    }
}

/// Technical Note TN2091の手順で、AVAudioEngineを使わずAUHALで指定した機器から取り込む。
/// formatは機器の入力側（input scope, element 1）から読み、同じformatを出力側へ設定するため、
/// 届くbufferのformatは常に`format`と一致する。
/// `@unchecked Sendable`: `start`と`stop`は所有する`MicCapture`（actor）からだけ呼ばれ、
/// render callbackはCore Audioのaudioのthreadで`sink`を読むだけである
final class AUHALPinnedCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case setupFailed(step: String, status: OSStatus)
        case notConfigured
    }

    private var audioUnit: AudioUnit?
    let format: AVAudioFormat
    private var sink: (any CaptureSink)?
    /// 直前のrender callbackの結果。audioのthreadだけが読み書きし、失敗が変わった時だけ伝える
    private var lastRenderFailure: OSStatus = noErr

    init?(deviceID: AudioDeviceID) {
        var descriptor = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &descriptor) else { return nil }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        var mutableDeviceID = deviceID
        var streamDescription = AudioStreamBasicDescription()
        var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let configured =
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enableInput, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disableOutput, UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            && AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                &streamDescription, &descriptionSize) == noErr
            && AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &streamDescription, descriptionSize) == noErr

        guard configured, let resolvedFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        audioUnit = unit
        format = resolvedFormat
    }

    /// render callbackを登録してから開始する。callbackは開始後にaudioのthreadから届くため、先に`sink`を設定する
    func start(into sink: any CaptureSink) throws {
        guard let audioUnit else { throw CaptureError.notConfigured }
        self.sink = sink

        var callback = AURenderCallbackStruct(
            inputProc: auhalPinnedCaptureRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let callbackStatus = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard callbackStatus == noErr else {
            throw CaptureError.setupFailed(step: "SetInputCallback", status: callbackStatus)
        }
        let initStatus = AudioUnitInitialize(audioUnit)
        guard initStatus == noErr else {
            throw CaptureError.setupFailed(step: "AudioUnitInitialize", status: initStatus)
        }
        let startStatus = AudioOutputUnitStart(audioUnit)
        guard startStatus == noErr else {
            throw CaptureError.setupFailed(step: "AudioOutputUnitStart", status: startStatus)
        }
    }

    func stop() {
        guard let audioUnit else { return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        sink = nil
    }

    fileprivate func render(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let audioUnit, let sink else { return noErr }
        guard inNumberFrames > 0 else { return noErr }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames) else {
            noteRenderFailure(kAudio_MemFullError, to: sink, what: "bufferを確保できません")
            return noErr
        }
        pcmBuffer.frameLength = inNumberFrames
        let status = AudioUnitRender(
            audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
            pcmBuffer.mutableAudioBufferList)
        guard status == noErr else {
            noteRenderFailure(status, to: sink, what: "AudioUnitRenderが失敗しました")
            return status
        }
        lastRenderFailure = noErr
        sink.ingest(pcmBuffer)
        return noErr
    }

    private func noteRenderFailure(_ status: OSStatus, to sink: any CaptureSink, what: String) {
        guard status != lastRenderFailure else { return }
        lastRenderFailure = status
        sink.noteError("固定した入力機器の音声を取り込めません（\(what): \(status)）")
    }
}

/// `AURenderCallback`は`@convention(c)`でclosureの捕捉を使えないため、`inRefCon`からインスタンスを戻す
private func auhalPinnedCaptureRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<AUHALPinnedCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(
        ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames)
}
```

- [ ] **Step 5: capture-daemonの繰り返しを置き換え、古い取り込みの経路を消す**

`Sources/notetaked/Commands/CaptureDaemonCommand.swift`を次の内容で置き換える:

```swift
import ArgumentParser
import Foundation
import NotetakeCore

struct CaptureDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-daemon",
        abstract: "Capture mic and system audio into the raw audio directory named by the desired state")

    func run() async throws {
        // 2つのcapture-daemonが同じ生音声へ書かないよう、状態ディレクトリのlockを取れなければ終わる
        let lockURL = CaptureStatePaths.stateDirectory().appendingPathComponent("capture-daemon.lock")
        guard let instanceLock = try InstanceLock.acquire(at: lockURL) else {
            Self.log("別のcapture-daemonが動いているため終了します")
            throw ExitCode.failure
        }
        defer { withExtendedLifetime(instanceLock) {} }
        let controller = CaptureController { source, pinnedInputUID -> any SourceCapture in
            if source == .system {
                return SystemAudioCapture()
            }
            return MicCapture(pinnedUID: pinnedInputUID)
        }
        let pid = getpid()
        let parent = getppid()

        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task { await Self.shutdown(controller, pid: pid) }
        }
        sigtermSource.resume()

        var watcher = DesiredStateWatcher(url: CaptureStatePaths.captureDesiredURL)
        // 実状態の書き込みの間隔は、時計の巻き戻りに左右されない単調な時計で測る
        let clock = ContinuousClock()
        var lastActualWrite: ContinuousClock.Instant?
        while true {
            // 起動したprocess（appかscript）が終わったら止める。動き続けると、次に起動したcapture-daemonと同じ生音声へ書くため
            if getppid() != parent {
                await Self.shutdown(controller, pid: pid)
            }
            switch watcher.poll() {
            case .changed(let desired):
                await controller.apply(desired)
                lastActualWrite = nil
            case .unreadable(let message):
                Self.log("望む状態を読めないため、いまの取り込みを続けます: \(message)")
            case nil:
                break
            }
            let now = Date()
            if lastActualWrite.map({ clock.now - $0 >= .seconds(1) }) ?? true {
                Self.writeActual(await controller.actualState(pid: pid, now: now))
                lastActualWrite = clock.now
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 取り込みを止め、止まった実状態を書いて終える
    private static func shutdown(_ controller: CaptureController, pid: Int32) async -> Never {
        await controller.stopAll()
        writeActual(await controller.actualState(pid: pid, now: Date()))
        Foundation.exit(0)
    }

    private static func writeActual(_ state: CaptureActualState) {
        do {
            try JSONFile.write(state, to: CaptureStatePaths.captureActualURL)
        } catch {
            log("実状態を書けません: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("capture-daemon: \(message)\n".utf8))
    }
}
```

古い経路を消す:

```bash
rm Sources/notetaked/Capture/CaptureSessionRunner.swift Sources/notetaked/Commands/CaptureCommand.swift
```

`Sources/notetaked/Notetaked.swift`のsubcommandから`Capture.self`を除く:

```swift
        subcommands: [Serve.self, Render.self, Transcribe.self, CaptureDaemon.self, Polish.self]
```

`Sources/NotetakeCore/Capture/CaptureStatePaths.swift`から`captureHeartbeatURL`の行を消す。

`Tests/NotetakeCoreTests/HeartbeatTests.swift`の`statePathsAreDistinct`の配列から`CaptureStatePaths.captureHeartbeatURL,`の行を消す。

`Apps/Notetake/CaptureDaemonSupervisor.swift`の型のcommentと`isHealthy`を置き換える:

```swift
/// notetaked capture-daemonを子processとして起動・監視する。capture-daemonは実状態のファイルを1秒ごとに書くため、
/// その更新時刻が15秒止まったら、落ちたかハングしたと見なして起動し直す
```

```swift
    var isHealthy: Bool {
        Heartbeat.currentStatus(of: CaptureStatePaths.captureActualURL, threshold: Self.heartbeatThreshold) == .alive
    }
```

- [ ] **Step 6: 通ることを確かめる**

Run: `swift test --filter 'retryBackoff|instanceLock|controller|recorder|statePaths'`
Expected: PASS

- [ ] **Step 7: 古い型への参照が残っていないことを確かめる**

Run: `grep -rn "CaptureSessionRunner\|captureHeartbeatURL\|struct Capture: AsyncParsableCommand" Sources Tests Apps`
Expected: `Sources/NotetakeCore/Capture/RawAudioWriter.swift:3:`のcomment（`CaptureSessionRunner`への言及）が1行だけ出る。このファイルはTask 12で消える

- [ ] **Step 8: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 9: commit（controller）**

```bash
git add -A Sources/notetaked Sources/NotetakeCore/Capture Apps/Notetake/CaptureDaemonSupervisor.swift Tests/NotetakeCoreTests/RetryBackoffTests.swift Tests/NotetakeCoreTests/InstanceLockTests.swift Tests/NotetakeCoreTests/HeartbeatTests.swift Tests/notetakedTests/CaptureControllerTests.swift
git commit -m "$(cat <<'MSG'
feat(capture): drive capture-daemon from the desired state

capture-daemon polls capture-desired.json every 200 ms, starts or stops
mic and system capture to match, switches the write directory without
stopping capture when only the prefix changes, and writes
capture-actual.json every second. ScreenCaptureKit stops arrive through
the stream delegate and the stream is rebuilt every 5 seconds; a failed
engine start on the mic is retried with backoff up to 30 seconds. The
capture subcommand and CaptureSessionRunner are gone, and the app judges
capture-daemon liveness by the actual state file.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 6: 消灯中にsystem音声を取り込めるかを確かめる（実機）

specは、消灯中にstreamを作り直して音を取り込めるかを段階1の最初に確かめ、取り込めなければsystem音声が鳴っている間だけ消灯を防ぐ、と決めている。Task 5で作り直しの仕組みができたため、ここで確かめ、Task 7を行うかを決める。capture-daemonだけを起動し、望む状態のファイルを手で書いて、system音声を取り込ませる（serveはまだ古い形式のため使わない）。

**Files:**
- Create: `.claude/skills/recordings/scripts/pcm-coverage.py`、`.claude/skills/daemon-realtest/scripts/display-sleep-check.sh`

- [ ] **Step 1: 生音声の量を見るscriptと、確認のscriptを置く**

`.claude/skills/recordings/scripts/pcm-coverage.py`:

```python
#!/usr/bin/env python3
"""生音声ディレクトリの1つのsourceについて、壁時計の区間ごとに書かれた音声の秒数と最大音量を出す。

usage: pcm-coverage.py <生音声ディレクトリ> <mic|system> [区間の秒数（既定10）]
"""
import array
import bisect
import datetime
import json
import math
import sys

SAMPLE_RATE = 16_000
BLOCK = 1_600  # 100ms


def load_meta(path):
    anchors, states = [], []
    with open(path, encoding="utf-8") as meta:
        for line in meta:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("t") == "anchor":
                anchors.append((record["sample"], record["ms"]))
            elif record.get("t") == "state":
                states.append(record)
    anchors.sort()
    return anchors, states


def wall_ms(anchors, starts, sample):
    index = bisect.bisect_right(starts, sample) - 1
    anchor_sample, anchor_ms = anchors[max(index, 0)]
    return anchor_ms + (sample - anchor_sample) * 1000 / SAMPLE_RATE


def clock(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%H:%M:%S")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    directory, source = sys.argv[1], sys.argv[2]
    bucket_seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    anchors, states = load_meta(f"{directory}/{source}.meta.jsonl")
    if not anchors:
        sys.exit("anchorがありません")
    starts = [sample for sample, _ in anchors]

    # 長い収録でもメモリに載せきらないよう、100msずつ読む
    buckets = {}
    offset = 0
    with open(f"{directory}/{source}.pcm", "rb") as pcm:
        while True:
            data = pcm.read(BLOCK * 4)
            if len(data) < 4:
                break
            block = array.array("f")
            block.frombytes(data[: len(data) // 4 * 4])
            rms = math.sqrt(sum(value * value for value in block) / len(block))
            dbfs = 20 * math.log10(rms) if rms > 0 else -120.0
            key = int(wall_ms(anchors, starts, offset) // (bucket_seconds * 1000))
            count, loudest = buckets.get(key, (0, -120.0))
            buckets[key] = (count + len(block), max(loudest, dbfs))
            offset += len(block)

    print(f"samples={offset} ({offset / SAMPLE_RATE:.1f}s) anchors={len(anchors)}")
    for record in states:
        print(f"state {clock(record['ms'])} sample={record['sample']} {record['state']} {record.get('reason') or ''}")
    for key in sorted(buckets):
        count, loudest = buckets[key]
        print(f"{clock(key * bucket_seconds * 1000)}  {count / SAMPLE_RATE:5.1f}s  max {loudest:7.1f} dBFS")


if __name__ == "__main__":
    main()
```

`.claude/skills/daemon-realtest/scripts/display-sleep-check.sh`:

```bash
#!/bin/bash
# capture-daemonだけを起動してsystem音声を取り込み、途中でディスプレイを90秒消灯させる。
# 消灯中もsystem音声を取り込めたかを、壁時計の10秒ごとの音声の量で確かめる。
# usage: display-sleep-check.sh <出力先directory>（repoのrootで、make daemonの完了後に実行する）
set -uo pipefail
D="$1"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
RAW="${TMPDIR:-/tmp}"
RAW="${RAW%/}/notetake-capture/display-check-$(date +%Y%m%d%H%M%S)"
# appと同じ状態ファイルを使うため、appやほかのnotetakedが動いている時は始めない
if pgrep -x Notetake > /dev/null || pgrep -f 'notetaked (serve|capture-daemon)' > /dev/null; then
  echo "Notetake.appかnotetakedが動いています。止めてから実行してください" >&2
  exit 1
fi
[ -x "$BIN" ] || { echo "$BINがありません。make daemonの後に実行してください" >&2; exit 1; }
mkdir -p "$D" "$STATE"

write_desired() {
  printf '%s' "$1" > "$STATE/capture-desired.json.tmp"
  mv "$STATE/capture-desired.json.tmp" "$STATE/capture-desired.json"
}

write_desired '{"sources":[]}'
"$BIN" capture-daemon 2> "$D/capture.err" &
DAEMON=$!
sleep 2
write_desired "{\"recording\":{\"prefix\":\"display-check\",\"directory\":\"$RAW\"},\"sources\":[\"system\"]}"
sleep 3
cp "$STATE/capture-actual.json" "$D/actual-start.json"

( for i in $(seq 1 45); do say -v Kyoko "消灯の確認、${i}番目です"; sleep 3; done ) &
SPEAKER=$!

sleep 20
date +%H:%M:%S > "$D/sleep-at"
pmset displaysleepnow
sleep 90
date +%H:%M:%S > "$D/wake-at"
caffeinate -u -t 2
sleep 40
cp "$STATE/capture-actual.json" "$D/actual-end.json"

write_desired '{"sources":[]}'
sleep 2
kill "$SPEAKER" 2>/dev/null
kill -TERM "$DAEMON"
for _ in $(seq 1 10); do
  kill -0 "$DAEMON" 2>/dev/null || break
  sleep 1
done
kill -9 "$DAEMON" 2>/dev/null
echo "$RAW" > "$D/raw-dir"
python3 .claude/skills/recordings/scripts/pcm-coverage.py "$RAW" system 10 > "$D/coverage.txt"
echo "done" > "$D/finished"
```

```bash
chmod +x .claude/skills/recordings/scripts/pcm-coverage.py .claude/skills/daemon-realtest/scripts/display-sleep-check.sh
bash -n .claude/skills/daemon-realtest/scripts/display-sleep-check.sh
python3 -m py_compile .claude/skills/recordings/scripts/pcm-coverage.py
```

Expected: どちらもerrorを出さない

- [ ] **Step 2: 前提を揃える**

- `pgrep -x Notetake`が何も返さない。動いていれば、止める前にuserへ「Notetake.appを止めます。収録中なら途中で終わります。よいですか?」と尋ね、了承を得てから`.claude/skills/mac-app/scripts/ntmenu.sh "終了"`で止める（appのcapture-daemonと状態ファイルを取り合うため）。動いていたことをledgerに残し、この確認が終わったらapp（`open /Applications/Notetake.app`）を起動し直す
- `make daemon`が終わっている。署名が終わる前に起動しない

- [ ] **Step 3: userに一声かける**

「これから約3分半、system音声で`say`の読み上げを流し、途中でディスプレイを90秒消灯します。点灯の後にロック画面が出たら解除してください。」と伝え、了承を得てから次へ進む。

- [ ] **Step 4: 確認を走らせる**

repoのrootで、`run_in_background`で走らせる（出力先はcontrollerのscratchpadの下にする）:

```bash
.claude/skills/daemon-realtest/scripts/display-sleep-check.sh <scratchpad>/display-check
```

終了の知らせを待つ（約3分半）。`<scratchpad>/display-check/finished`ができていれば終わっている。

- [ ] **Step 5: 判定して記録する**

```bash
cat <scratchpad>/display-check/sleep-at <scratchpad>/display-check/wake-at
cat <scratchpad>/display-check/coverage.txt
cat <scratchpad>/display-check/actual-start.json
```

- `actual-start.json`のsystemが`retrying`で、理由が許可の不足（`The user declined`など）なら、取り込み自体ができていない。userに、端末のappへ「画面とシステムオーディオの録音」の許可を頼んでからStep 4をやり直す。許可を得られない時は、この確認をTask 13の後へ回し、Notetake.appで収録を始めて同じ手順（`say`の繰り返し、`pmset displaysleepnow`、90秒後の`caffeinate -u -t 2`）を行い、appの生音声ディレクトリに`pcm-coverage.py`をかける（appが起動したcapture-daemonはappの許可を使う）
- 判定A（消灯中も取り込める）: `sleep-at`の10秒後から`wake-at`の10秒前までの10秒区間の7割以上で、音声が5秒以上あり、最大の音量が-40dBFSより大きい。Task 7は行わない
- 判定B（消灯中は取り込めない）: Aに当たらない。Task 7を行う
- どちらでも、`state`行（`retrying`と`recording`の時刻）と、`say`の合間の無音の区間に音声があるか（ScreenCaptureKitが無音の間もbufferを渡すか）を、SDDのledgerに書く。Task 15でHANDOFFの「環境の注意」に移す

- [ ] **Step 6: commit（controller）**

```bash
git add .claude/skills/recordings/scripts/pcm-coverage.py .claude/skills/daemon-realtest/scripts/display-sleep-check.sh
git commit -m "$(cat <<'MSG'
chore(skill): add raw audio coverage and display sleep check scripts

pcm-coverage.py maps a raw audio file onto wall-clock buckets through
its anchors and prints how much audio each bucket holds and how loud it
is. display-sleep-check.sh runs capture-daemon alone, plays speech as
system audio and puts the display to sleep for 90 seconds, so the
coverage shows whether system audio survives the display going off.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 7: system音声が鳴っている間だけ消灯を防ぐ（Task 6が判定Bの時だけ）

Task 6が判定Aなら、このtaskは行わない。ledgerに「Task 7は不要（消灯中も取り込める）」と書いて、Task 8へ進む。

判定Bの時は、system音声に無音でない音（-70dBFSより大きい）が直近5分以内にあった間だけ、`PreventUserIdleDisplaySleep`のassertionを持つ。音が5分途切れた時、収録が止まった時、または望む状態のsourcesからsystemが外れた時に離し、OSの消灯とロックに戻す。常駐で長時間収録するため、収録中ずっと消灯を防ぐことはしない。assertionを作れなかった時は、音のbufferのたびに作り直さず、10秒に1回までにする（失敗の記録も同じ頻度になる）。assertionの種類はCの定数（`kIOPMAssertPreventUserIdleDisplaySleep`はCFSTRのmacroでSwiftから見えない）ではなく文字列`"PreventUserIdleDisplaySleep"`で渡す。

**Files:**
- Create: `Sources/NotetakeCore/Capture/DisplaySleepPolicy.swift`、`Sources/notetaked/Capture/DisplaySleepGuard.swift`
- Modify: `Sources/notetaked/Capture/SourceRecorder.swift`、`Sources/notetaked/Capture/CaptureController.swift`
- Replace: `Sources/notetaked/Commands/CaptureDaemonCommand.swift`
- Test: `Tests/NotetakeCoreTests/DisplaySleepPolicyTests.swift`

**Interfaces:**
- Consumes: `SourceRecorder`（Task 4）、`CaptureController`（Task 5）、`AudioLevel.dbfs(_ samples: [Float])`（既存）
- Produces: `DisplaySleepPolicy.isSound(_:)`、`DisplaySleepPolicy.shouldHold(lastSoundAt:now:)`。`DisplaySleepGuard`の`noteLevel(_:at:)`、`refresh(now:)`、`release()`。`SourceRecorder.init(source:now:onLevel:)`、`CaptureController.init(makeCapture:onLevel:)`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/DisplaySleepPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func displaySleepPolicyHoldsForFiveMinutesAfterSound() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(DisplaySleepPolicy.shouldHold(lastSoundAt: nil, now: now) == false)
    #expect(DisplaySleepPolicy.shouldHold(lastSoundAt: now.addingTimeInterval(-299), now: now))
    #expect(DisplaySleepPolicy.shouldHold(lastSoundAt: now.addingTimeInterval(-300), now: now) == false)
    #expect(DisplaySleepPolicy.isSound(-60))
    #expect(DisplaySleepPolicy.isSound(-120) == false)
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter displaySleepPolicy`
Expected: buildが`cannot find 'DisplaySleepPolicy' in scope`で失敗する

- [ ] **Step 3: 判断と保持を実装する**

`Sources/NotetakeCore/Capture/DisplaySleepPolicy.swift`:

```swift
import Foundation

/// system音声を取り込むために、ディスプレイの消灯を防ぎ続けるかの判断
public enum DisplaySleepPolicy {
    /// 最後に音があってから、消灯を防ぎ続ける秒数
    public static let holdSeconds: TimeInterval = 300
    /// これより大きい音量を、無音でない音として扱う
    public static let soundThresholdDBFS: Double = -70

    public static func isSound(_ dbfs: Double) -> Bool {
        dbfs > soundThresholdDBFS
    }

    public static func shouldHold(lastSoundAt: Date?, now: Date) -> Bool {
        guard let lastSoundAt else { return false }
        return now.timeIntervalSince(lastSoundAt) < holdSeconds
    }
}
```

`Sources/notetaked/Capture/DisplaySleepGuard.swift`:

```swift
import Foundation
import IOKit.pwr_mgt
import NotetakeCore

/// system音声に無音でない音が直近5分以内にあった間だけ、ディスプレイの消灯を防ぐ。
/// 消灯中はScreenCaptureKitがsystem音声を取り込めないため。音が5分途切れるか、system音声を使わなくなると離し、
/// OSの消灯とロックへ戻す。assertionを作れなかった時は、10秒に1回までしか作り直さない
final class DisplaySleepGuard: @unchecked Sendable {
    // @unchecked Sendable: 可変の状態はlockの内側でだけ読み書きする
    private let lock = NSLock()
    private var lastSoundAt: Date?
    private var assertionID: IOPMAssertionID?
    private var lastFailedAttempt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func noteLevel(_ dbfs: Double, at time: Date) {
        guard DisplaySleepPolicy.isSound(dbfs) else { return }
        lock.withLock {
            lastSoundAt = time
            if assertionID == nil, canRetryCreation() {
                assertionID = createAssertion()
            }
        }
    }

    func refresh(now: Date) {
        lock.withLock {
            if !DisplaySleepPolicy.shouldHold(lastSoundAt: lastSoundAt, now: now) {
                releaseAssertion()
            }
        }
    }

    func release() {
        lock.withLock {
            lastSoundAt = nil
            releaseAssertion()
        }
    }

    private func releaseAssertion() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    private func canRetryCreation() -> Bool {
        guard let lastFailedAttempt else { return true }
        return clock.now - lastFailedAttempt >= .seconds(10)
    }

    private func createAssertion() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Notetake: system音声を取り込んでいます" as CFString, &id)
        guard result == kIOReturnSuccess else {
            lastFailedAttempt = clock.now
            FileHandle.standardError.write(Data("capture-daemon: 消灯を防げません: \(result)\n".utf8))
            return nil
        }
        lastFailedAttempt = nil
        return id
    }
}
```

- [ ] **Step 4: 書き手から音量を受け取れるようにする**

`Sources/notetaked/Capture/SourceRecorder.swift`の`private let now: @Sendable () -> Date`の次に足す:

```swift
    private let onLevel: (@Sendable (Double, Date) -> Void)?
```

`init`を置き換える:

```swift
    init(
        source: Source, now: @escaping @Sendable () -> Date = { Date() },
        onLevel: (@Sendable (Double, Date) -> Void)? = nil
    ) {
        self.source = source
        self.now = now
        self.onLevel = onLevel
        queue = DispatchQueue(label: "io.github.bash0c7.notetaked.recorder.\(source.rawValue)")
        status = CaptureActualState.SourceStatus(source: source, state: .off)
    }
```

`write(_:)`の`guard !samples.isEmpty else { return }`の次に足す:

```swift
        onLevel?(AudioLevel.dbfs(samples), chunk.receivedAt)
```

`Sources/notetaked/Capture/CaptureController.swift`の`private let makeCapture: CaptureFactory`の次に足す:

```swift
    private let onLevel: @Sendable (Source, Double, Date) -> Void
```

`init`を置き換える:

```swift
    init(
        makeCapture: @escaping CaptureFactory,
        onLevel: @escaping @Sendable (Source, Double, Date) -> Void = { _, _, _ in }
    ) {
        self.makeCapture = makeCapture
        self.onLevel = onLevel
    }
```

`apply(_:)`の`let recorder = SourceRecorder(source: source)`を置き換える:

```swift
            let onLevel = self.onLevel
            let recorder = SourceRecorder(source: source, onLevel: { onLevel(source, $0, $1) })
```

`Sources/notetaked/Commands/CaptureDaemonCommand.swift`を次の内容で置き換える:

```swift
import ArgumentParser
import Foundation
import NotetakeCore

struct CaptureDaemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-daemon",
        abstract: "Capture mic and system audio into the raw audio directory named by the desired state")

    func run() async throws {
        // 2つのcapture-daemonが同じ生音声へ書かないよう、状態ディレクトリのlockを取れなければ終わる
        let lockURL = CaptureStatePaths.stateDirectory().appendingPathComponent("capture-daemon.lock")
        guard let instanceLock = try InstanceLock.acquire(at: lockURL) else {
            Self.log("別のcapture-daemonが動いているため終了します")
            throw ExitCode.failure
        }
        defer { withExtendedLifetime(instanceLock) {} }
        let displayGuard = DisplaySleepGuard()
        let controller = CaptureController(
            makeCapture: { source, pinnedInputUID -> any SourceCapture in
                if source == .system {
                    return SystemAudioCapture()
                }
                return MicCapture(pinnedUID: pinnedInputUID)
            },
            onLevel: { source, dbfs, time in
                if source == .system {
                    displayGuard.noteLevel(dbfs, at: time)
                }
            })
        let pid = getpid()
        let parent = getppid()

        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task { await Self.shutdown(controller, displayGuard, pid: pid) }
        }
        sigtermSource.resume()

        var watcher = DesiredStateWatcher(url: CaptureStatePaths.captureDesiredURL)
        // 実状態の書き込みの間隔は、時計の巻き戻りに左右されない単調な時計で測る
        let clock = ContinuousClock()
        var lastActualWrite: ContinuousClock.Instant?
        while true {
            // 起動したprocess（appかscript）が終わったら止める。動き続けると、次に起動したcapture-daemonと同じ生音声へ書くため
            if getppid() != parent {
                await Self.shutdown(controller, displayGuard, pid: pid)
            }
            switch watcher.poll() {
            case .changed(let desired):
                await controller.apply(desired)
                if desired.recording == nil || !desired.sources.contains(.system) {
                    displayGuard.release()
                }
                lastActualWrite = nil
            case .unreadable(let message):
                Self.log("望む状態を読めないため、いまの取り込みを続けます: \(message)")
            case nil:
                break
            }
            let now = Date()
            if lastActualWrite.map({ clock.now - $0 >= .seconds(1) }) ?? true {
                displayGuard.refresh(now: now)
                Self.writeActual(await controller.actualState(pid: pid, now: now))
                lastActualWrite = clock.now
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 取り込みを止め、消灯を防ぐassertionを離し、止まった実状態を書いて終える
    private static func shutdown(
        _ controller: CaptureController, _ displayGuard: DisplaySleepGuard, pid: Int32
    ) async -> Never {
        await controller.stopAll()
        displayGuard.release()
        writeActual(await controller.actualState(pid: pid, now: Date()))
        Foundation.exit(0)
    }

    private static func writeActual(_ state: CaptureActualState) {
        do {
            try JSONFile.write(state, to: CaptureStatePaths.captureActualURL)
        } catch {
            log("実状態を書けません: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("capture-daemon: \(message)\n".utf8))
    }
}
```

- [ ] **Step 5: 通ることを確かめる**

Run: `swift test --filter 'displaySleepPolicy|recorder|controller'`
Expected: PASS

- [ ] **Step 6: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 7: 実機でassertionの出入りを確かめる**

`make daemon`の完了後、Task 6のStep 2と同じ前提で、次のscriptを`<scratchpad>/display-guard/check.sh`に置き、`run_in_background`で走らせる:

```bash
#!/bin/bash
set -uo pipefail
D="$1"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
RAW="${TMPDIR%/}/notetake-capture/display-guard-$(date +%Y%m%d%H%M%S)"
mkdir -p "$D"
write_desired() {
  printf '%s' "$1" > "$STATE/capture-desired.json.tmp"
  mv "$STATE/capture-desired.json.tmp" "$STATE/capture-desired.json"
}
write_desired '{"sources":[]}'
"$BIN" capture-daemon 2> "$D/capture.err" &
DAEMON=$!
sleep 2
write_desired "{\"recording\":{\"prefix\":\"display-guard\",\"directory\":\"$RAW\"},\"sources\":[\"system\"]}"
sleep 3
pmset -g assertions | grep -c 'Notetake: system音声' > "$D/before-sound.txt"
say -v Kyoko "消灯を防ぐ確認です"
sleep 2
pmset -g assertions | grep 'Notetake: system音声' > "$D/while-sound.txt"
write_desired '{"sources":[]}'
sleep 3
pmset -g assertions | grep -c 'Notetake: system音声' > "$D/after-stop.txt"
kill -TERM "$DAEMON"
wait "$DAEMON"
echo done > "$D/finished"
```

Run（`run_in_background`）: `bash <scratchpad>/display-guard/check.sh <scratchpad>/display-guard`
Expected: `before-sound.txt`が`0`、`while-sound.txt`に`PreventUserIdleDisplaySleep`の行がある、`after-stop.txt`が`0`

- [ ] **Step 8: commit（controller）**

```bash
git add Sources/NotetakeCore/Capture/DisplaySleepPolicy.swift Sources/notetaked/Capture/DisplaySleepGuard.swift Sources/notetaked/Capture/SourceRecorder.swift Sources/notetaked/Capture/CaptureController.swift Sources/notetaked/Commands/CaptureDaemonCommand.swift Tests/NotetakeCoreTests/DisplaySleepPolicyTests.swift
git commit -m "$(cat <<'MSG'
feat(capture): keep the display awake while system audio is playing

ScreenCaptureKit cannot capture system audio while the display is off.
capture-daemon now holds a PreventUserIdleDisplaySleep assertion only
while non-silent system audio arrived within the last five minutes, and
releases it once the audio has been quiet that long or recording stops.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 8: 生音声の読み手と、ライブの時刻の対応

serveがライブの文字起こしで使う部品を作る。`.pcm`と`.meta.jsonl`はcapture-daemonが追記し続けるため、書きかけの端数byteと改行の無い行は次回へ回す。読む順番は`.pcm`の後に`.meta.jsonl`とする。書き手はsampleより先にそのanchorを書くため、この順で読めば、読んだsampleの時刻は必ず分かる。

文字起こし（`Transcriber`）の時刻の原点を1970年（epoch 0）にすると、発話の時刻は「文字起こしへ最初に渡したsampleからのms」になる。`LivePieceLocator`はこれを生音声のsample範囲と壁時計へ直す。

停止と区切りでは、確定していない発話を待たずに文字起こしを打ち切る（`cancelAndFinishNow()`）。完成版は段階2の確定処理が作る。serveが収録を途中から引き継ぐ時のため、`timed.jsonl`を畳み込んで続きの`seq`を求める`Reconciler.restore`も足す。

**Files:**
- Create: `Sources/NotetakeCore/Capture/RawAudioTail.swift`
- Modify: `Sources/NotetakeCore/Transcribe/Transcriber.swift`（`cancel()`と`resultsError()`を足す）、`Sources/NotetakeCore/Reconcile/Reconciler.swift`（`restore`を足す）
- Test: `Tests/NotetakeCoreTests/RawAudioTailTests.swift`、`Tests/NotetakeCoreTests/ReconcilerTests.swift`（1件足す）

**Interfaces:**
- Consumes: `CapturePCM`、`CaptureMetaLine`、`CaptureTimeline`（Task 2）
- Produces:
  - `final class PCMTailReader`: `init(url:startSample:)`、`nextSample`、`readNew(maxSamples: Int = 160_000) throws -> [Float]`、`static sampleCount(of:) -> Int64`、`static samples(in: Range<Int64>, of: URL) throws -> [Float]`
  - `final class MetaTailReader`: `init(url:)`、`readNew() throws -> [CaptureMetaLine]`
  - `struct LivePieceLocator`: `init(firstSample:)`、`var timeline: CaptureTimeline`、`locate(startMS:endMS:) -> Location?`（`Location`は`samples: Range<Int64>`、`startMS`、`endMS`、`input: InputDevice?`）
  - `Transcriber.cancel() async`、`Transcriber.resultsError() -> Error?`（結果のsequenceが失敗で終わっていればその失敗）
  - `Reconciler.restore(from records: [Record], device: String) -> (reconciler: Reconciler, lastSeq: Int)`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/RawAudioTailTests.swift`:

```swift
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
```

`Tests/NotetakeCoreTests/ReconcilerTests.swift`の末尾に足す:

```swift
@Test func restoreFoldsRecordsAndFindsTheLastSeqOfTheDevice() {
    func segment(device: String, seq: Int, start: Int64, text: String) -> Record {
        .segment(
            Segment(
                id: UUID(), session: "s1", seq: seq, device: device, deviceName: device, owner: "山田",
                platform: .mac, source: .mic, input: .test, start: start, end: start + 1000, text: text))
    }

    let restored = Reconciler.restore(
        from: [
            segment(device: "mac1", seq: 7, start: 0, text: "こんにちは"),
            segment(device: "iphone1", seq: 40, start: 5000, text: "資料を送っておきますね"),
        ],
        device: "mac1")

    #expect(restored.lastSeq == 7)
    #expect(restored.reconciler.utterances.count == 2)
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'pcmTailReader|metaTailReader|livePieceLocator|restoreFolds'`
Expected: buildが`cannot find 'PCMTailReader' in scope`などで失敗する

- [ ] **Step 3: 実装する**

`Sources/NotetakeCore/Capture/RawAudioTail.swift`:

```swift
import Foundation

/// capture-daemonが追記し続ける`.pcm`を読み進める。書きかけの端数byteは読まずに次回へ回す
public final class PCMTailReader {
    public let url: URL
    /// 次に返すsampleの番号
    public private(set) var nextSample: Int64
    private var handle: FileHandle?

    public init(url: URL, startSample: Int64) {
        self.url = url
        self.nextSample = startSample
    }

    deinit {
        try? handle?.close()
    }

    /// いまファイルにある完全なsampleの数。ファイルが無ければ0
    public static func sampleCount(of url: URL) -> Int64 {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value / Int64(CapturePCM.bytesPerSample)
    }

    /// 前回の続きから、書き終わったsampleを最大`maxSamples`個返す。ファイルがまだ無ければ空
    public func readNew(maxSamples: Int = 160_000) throws -> [Float] {
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            handle = try FileHandle(forReadingFrom: url)
        }
        guard let handle else { return [] }
        try handle.seek(toOffset: UInt64(nextSample) * UInt64(CapturePCM.bytesPerSample))
        guard let data = try handle.read(upToCount: maxSamples * CapturePCM.bytesPerSample) else { return [] }
        let samples = CapturePCM.decode(data)
        nextSample += Int64(samples.count)
        return samples
    }

    /// `range`のsampleを読む。ファイルの終わりを超える分は返さない
    public static func samples(in range: Range<Int64>, of url: URL) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound) * UInt64(CapturePCM.bytesPerSample))
        let data = try handle.read(upToCount: Int(range.count) * CapturePCM.bytesPerSample) ?? Data()
        return CapturePCM.decode(data)
    }
}

/// `.meta.jsonl`の新しい行を読む。改行で終わっていない最後の行は次回へ回す。
/// 解釈できない行は、書き手が書きかけで落ちた行なので飛ばす
public final class MetaTailReader {
    public let url: URL
    private var offset: UInt64 = 0
    private var handle: FileHandle?

    public init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    public func readNew() throws -> [CaptureMetaLine] {
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            handle = try FileHandle(forReadingFrom: url)
        }
        guard let handle else { return [] }
        try handle.seek(toOffset: offset)
        guard let data = try handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? CaptureMetaLine.decode(line: String($0)) }
    }
}

/// ライブの文字起こしの時刻（文字起こしへ最初に渡したsampleを0とするms）を、
/// 生音声のsample範囲と壁時計へ直す
public struct LivePieceLocator: Sendable {
    public struct Location: Equatable, Sendable {
        public var samples: Range<Int64>
        public var startMS: Int64
        public var endMS: Int64
        public var input: InputDevice?
    }

    /// 文字起こしへ最初に渡したsampleの番号
    public let firstSample: Int64
    public var timeline = CaptureTimeline()

    public init(firstSample: Int64) {
        self.firstSample = firstSample
    }

    /// anchorがまだ無ければnil
    public func locate(startMS: Int64, endMS: Int64) -> Location? {
        let start = firstSample + CapturePCM.samples(forMS: max(0, startMS))
        let end = max(start, firstSample + CapturePCM.samples(forMS: max(0, endMS)))
        guard let wallStart = timeline.ms(atSample: start), let wallEnd = timeline.ms(atSample: end) else {
            return nil
        }
        return Location(
            samples: start..<end, startMS: wallStart, endMS: max(wallStart, wallEnd),
            input: timeline.device(atSample: start))
    }
}
```

`Sources/NotetakeCore/Transcribe/Transcriber.swift`の`private static func makePiece(from result:`の前に足す:

```swift
    /// 結果のsequenceが失敗で終わっていれば、その失敗
    public func resultsError() -> Error? {
        resultsLoopError
    }

    /// 入力を閉じ、確定していない発話を待たずに終える。収録の停止と区切りで使う
    public func cancel() async {
        inputContinuation?.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        piecesContinuation?.finish()
    }

```

`Sources/NotetakeCore/Reconcile/Reconciler.swift`の末尾に足す:

```swift

extension Reconciler {
    /// 既存の`timed.jsonl`の記録を畳み込み、`device`のsegの最大の`seq`を返す。
    /// serveが収録を途中から引き継ぐ時に、表示と`seq`を続きから始めるために使う
    public static func restore(from records: [Record], device: String) -> (reconciler: Reconciler, lastSeq: Int) {
        var reconciler = Reconciler()
        var lastSeq = 0
        for record in records {
            reconciler.apply(record)
            if case .segment(let segment) = record, segment.device == device {
                lastSeq = max(lastSeq, segment.seq)
            }
        }
        return (reconciler, lastSeq)
    }
}
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'pcmTailReader|metaTailReader|livePieceLocator|restoreFolds'`
Expected: PASS（5件）

- [ ] **Step 5: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/NotetakeCore/Capture/RawAudioTail.swift Sources/NotetakeCore/Transcribe/Transcriber.swift Sources/NotetakeCore/Reconcile/Reconciler.swift Tests/NotetakeCoreTests/RawAudioTailTests.swift Tests/NotetakeCoreTests/ReconcilerTests.swift
git commit -m "$(cat <<'MSG'
feat(core): read growing raw audio and place live pieces on the wall clock

PCMTailReader and MetaTailReader follow the files capture-daemon keeps
appending, leaving partial samples and lines for the next read.
LivePieceLocator turns transcriber times, measured from the first fed
sample, into sample ranges and wall-clock times through the anchors.
Transcriber gains cancel() for stopping without waiting to finalize
and resultsError() for reporting a results sequence that failed, and Reconciler.restore folds an existing timed.jsonl when serve resumes
a recording.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 9: ライブの文字起こし（LiveTranscription）

sourceごとに1つ持ち、`<source>.pcm`の末尾を100msごとに読み、文字起こしの入力形式（この機械では16kHz monoのInt16）へ`AudioConverter`で変換して渡す。sample rateは同じなのでresampleは起きない。発話の時刻はanchorから、入力機器はdevice行から、音量は発話の範囲のsampleから求める。systemの入力機器は`InputDevice.system`、micでdevice行がまだ無い時は`InputDeviceProbe.current()`にする。文字起こしの入力のsample rateが16kHzでなければ、発話の時刻とsampleの対応が崩れるため`init`で投げる。

失敗は握りつぶさない。生音声を読めない、時刻の記録（meta）を読めない、変換できない、はそれぞれ`log`で1度だけ伝える。metaを読めなくても読んだsampleは文字起こしへ渡し、変換できなくても渡せなかった分のframe数を進めて、以後の発話の時刻とsampleの対応を保つ。文字起こしの結果のsequenceが、`stop()`でないのに失敗で終わったら、以後の発話が出ないため`error`で伝える。

文字起こしは、発話の後に音声が続かないと発話を確定させない。収録中はmicの無音が流れ続けるため確定するが、テストでは無音を書き足し続けて確定させる。テストは`say -v Kyoko`で音声を作り、ja-JPの音声資産を使う（開発機には入っている）。1件に10秒ほどかかる。

**Files:**
- Create: `Sources/notetaked/Pipeline/LiveTranscription.swift`
- Test: `Tests/notetakedTests/LiveTranscriptionTests.swift`

**Interfaces:**
- Consumes: `PCMTailReader`、`MetaTailReader`、`LivePieceLocator`、`Transcriber.cancel()`・`Transcriber.resultsError()`（Task 8）、`CaptureSessionPaths.pcmURL/metaURL`（Task 2）、`AudioConverter`、`AudioLevel`、`InputDeviceProbe`（既存）、`MonoResampler`・`CapturedChunk`（Task 4、テストだけ）
- Produces: `actor LiveTranscription`: `init(source: Source, sessionDirectory: URL, locale: Locale, startAtEnd: Bool) async throws`、`start() async throws -> AsyncStream<Output>`、`stop() async`。`enum Output { case volatile(String); case final(Piece); case log(String); case error(String) }`、`static func validateInputSampleRate(_:) throws`（16kHzでなければ`SetupError.unsupportedSampleRate`）、`struct Piece { text, startMS, endMS, confidence: Double?, levelDBFS: Double, input: InputDevice }`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/notetakedTests/LiveTranscriptionTests.swift`:

```swift
import AVFoundation
import Foundation
import NotetakeCore
import Testing
@testable import notetaked

/// 出力を任意のthreadから集める
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [LiveTranscription.Output] = []

    func append(_ output: LiveTranscription.Output) {
        lock.withLock { outputs.append(output) }
    }

    var errors: [String] {
        lock.withLock { outputs.compactMap { if case .error(let message) = $0 { message } else { nil } } }
    }

    var finals: [LiveTranscription.Piece] {
        lock.withLock { outputs.compactMap { if case .final(let piece) = $0 { piece } else { nil } } }
    }
}

private func appendSilence(to url: URL, samples: Int) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: CapturePCM.encode([Float](repeating: 0, count: samples)))
}

@Test(.timeLimit(.minutes(1))) func liveTranscriptionGivesWallClockTimesToPieces() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let speechURL = directory.appendingPathComponent("speech.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Kyoko", "-o", speechURL.path, "これはライブの文字起こしの確認です。"]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0)

    let file = try AVAudioFile(forReading: speechURL)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let resampler = MonoResampler()
    let speech = try resampler.convert(try #require(CapturedChunk(buffer: buffer, receivedAt: Date())))
        + resampler.flush()
    let pcmURL = CaptureSessionPaths.pcmURL(sessionDirectory: directory, source: .system)
    try CapturePCM.encode([Float](repeating: 0, count: 16_000) + speech).write(to: pcmURL)
    let anchorMS: Int64 = 1_800_000_000_000
    let anchor = try CaptureMetaLine.anchor(CaptureAnchor(sample: 0, ms: anchorMS)).encodedLine()
    try Data((anchor + "\n").utf8).write(
        to: CaptureSessionPaths.metaURL(sessionDirectory: directory, source: .system))

    let live = try await LiveTranscription(
        source: .system, sessionDirectory: directory, locale: Locale(identifier: "ja-JP"), startAtEnd: false)
    let outputs = try await live.start()
    let collector = OutputCollector()
    let consumer = Task {
        for await output in outputs {
            collector.append(output)
        }
    }
    // 収録中と同じように無音を書き足し続けると、文字起こしが発話を確定させる
    let deadline = Date().addingTimeInterval(40)
    while collector.finals.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(200))
        try appendSilence(to: pcmURL, samples: 3_200)
    }
    await live.stop()
    await consumer.value

    let piece = try #require(collector.finals.first)
    #expect(piece.startMS >= anchorMS + 500)
    #expect(piece.endMS > piece.startMS)
    #expect(piece.input == .system)
    #expect(piece.levelDBFS > -60)
}

@Test(.timeLimit(.minutes(1))) func liveTranscriptionStopsBeforeAnyAudioArrives() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let live = try await LiveTranscription(
        source: .mic, sessionDirectory: directory, locale: Locale(identifier: "ja-JP"), startAtEnd: false)
    let outputs = try await live.start()
    let collector = OutputCollector()
    let consumer = Task {
        for await output in outputs {
            collector.append(output)
        }
    }
    try await Task.sleep(for: .milliseconds(300))
    await live.stop()
    await consumer.value
    // 自分で止めた時は、文字起こしが止まった失敗として伝えない
    #expect(collector.errors.isEmpty)
}

@Test func liveTranscriptionRejectsAnInputThatIsNotSixteenKilohertz() throws {
    try LiveTranscription.validateInputSampleRate(16_000)
    #expect(throws: LiveTranscription.SetupError.unsupportedSampleRate(48_000)) {
        try LiveTranscription.validateInputSampleRate(48_000)
    }
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter liveTranscription`
Expected: buildが`cannot find 'LiveTranscription' in scope`で失敗する

- [ ] **Step 3: 実装する**

`Sources/notetaked/Pipeline/LiveTranscription.swift`:

```swift
import AVFoundation
import Foundation
import NotetakeCore

/// 収録中、1つのsourceの生音声を末尾まで追いかけて文字起こしする。
/// 発話の時刻は`.meta.jsonl`のanchorから壁時計に直し、入力機器はdevice行から、音量は発話の範囲のsampleから求める
actor LiveTranscription {
    struct Piece: Sendable {
        let text: String
        let startMS: Int64
        let endMS: Int64
        let confidence: Double?
        let levelDBFS: Double
        let input: InputDevice
    }

    enum Output: Sendable {
        case volatile(String)
        case final(Piece)
        case log(String)
        /// 文字起こしが途中で止まるなど、以後の発話が出なくなる失敗
        case error(String)
    }

    enum SetupError: Error, Equatable {
        /// 生音声は16kHzで、文字起こしの入力とsample数が一致する前提で時刻を求めている
        case unsupportedSampleRate(Double)
    }

    /// 文字起こしの入力が生音声と同じsample rateか確かめる。違えば時刻の対応が崩れる
    static func validateInputSampleRate(_ rate: Double) throws {
        guard rate == Double(CapturePCM.sampleRate) else { throw SetupError.unsupportedSampleRate(rate) }
    }

    private static let pollInterval: Duration = .milliseconds(100)

    private let source: Source
    private let pcmURL: URL
    private let pcm: PCMTailReader
    private let meta: MetaTailReader
    private var locator: LivePieceLocator
    private let transcriber: Transcriber
    private let sourceFormat: AVAudioFormat
    private let converter: AudioConverter
    private var fedFrames: AVAudioFramePosition = 0
    private var pollTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?
    private var continuation: AsyncStream<Output>.Continuation?
    private var lastReportedError: String?
    private var stopping = false

    /// `startAtEnd`がtrueなら、生音声の現在の末尾から読む（serveが収録を途中から引き継ぐ時）
    init(source: Source, sessionDirectory: URL, locale: Locale, startAtEnd: Bool) async throws {
        self.source = source
        pcmURL = CaptureSessionPaths.pcmURL(sessionDirectory: sessionDirectory, source: source)
        let firstSample = startAtEnd ? PCMTailReader.sampleCount(of: pcmURL) : 0
        pcm = PCMTailReader(url: pcmURL, startSample: firstSample)
        meta = MetaTailReader(url: CaptureSessionPaths.metaURL(sessionDirectory: sessionDirectory, source: source))
        locator = LivePieceLocator(firstSample: firstSample)
        // 時刻の原点を1970年にすると、発話の時刻は文字起こしへ渡した最初のsampleからのmsになる
        transcriber = try await Transcriber(locale: locale, origin: Date(timeIntervalSince1970: 0))
        try Self.validateInputSampleRate(transcriber.inputFormat.sampleRate)
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(CapturePCM.sampleRate), channels: 1,
                interleaved: false)
        else {
            preconditionFailure("16kHz mono Float32 is always a valid format")
        }
        self.sourceFormat = sourceFormat
        converter = try AudioConverter(from: sourceFormat, to: transcriber.inputFormat)
    }

    func start() async throws -> AsyncStream<Output> {
        let pieces = try await transcriber.start()
        let (stream, continuation) = AsyncStream<Output>.makeStream()
        self.continuation = continuation
        forwardTask = Task {
            for await piece in pieces {
                self.accept(piece)
            }
            await self.reportResultsEnd()
        }
        pollTask = Task {
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        return stream
    }

    /// 文字起こしを打ち切る。最後の数秒の発話は出ないことがある
    func stop() async {
        stopping = true
        pollTask?.cancel()
        await pollTask?.value
        await transcriber.cancel()
        await forwardTask?.value
        continuation?.finish()
    }

    private func pollOnce() async {
        let samples: [Float]
        do {
            samples = try pcm.readNew()
        } catch {
            report("ライブの文字起こしで生音声を読めません: \(error)")
            return
        }
        // 書き手はsampleより先にそのanchorを書くため、sampleを読んだ後にmetaを読めば時刻が揃う。
        // metaを読めなくても、読んだsampleは文字起こしへ渡す
        do {
            for line in try meta.readNew() {
                locator.timeline.apply(line)
            }
        } catch {
            report("ライブの文字起こしで時刻の記録を読めません: \(error)")
        }
        guard !samples.isEmpty else { return }
        do {
            let converted = try converter.convert(try makeBuffer(samples))
            let frames = AVAudioFramePosition(converted.frameLength)
            await transcriber.feed(converted, at: fedFrames)
            fedFrames += frames
        } catch {
            // 渡せなかった分も数え、以後の発話の時刻とsampleの対応を保つ（入力は生音声と同じsample rate）
            fedFrames += AVAudioFramePosition(samples.count)
            report("ライブの文字起こしへ生音声を渡せません: \(error)")
        }
    }

    /// 結果が打ち切りでなく終わったら、以後の発話が出ないため失敗として伝える
    private func reportResultsEnd() async {
        guard !stopping else { return }
        let reason = await transcriber.resultsError().map { "\($0)" } ?? "結果が途中で終わりました"
        continuation?.yield(.error("\(source.rawValue)のライブの文字起こしが止まりました: \(reason)"))
    }

    private func accept(_ piece: TranscriptPiece) {
        guard piece.isFinal else {
            continuation?.yield(.volatile(piece.text))
            return
        }
        guard let location = locator.locate(startMS: piece.startMS, endMS: piece.endMS) else {
            report("時刻の基準点が無いため発話を出せません: \(piece.text)")
            return
        }
        let level: Double
        do {
            level = AudioLevel.dbfs(try PCMTailReader.samples(in: location.samples, of: pcmURL))
        } catch {
            report("発話の音量を読めません: \(error)")
            level = -120
        }
        let input = source == .system ? InputDevice.system : (location.input ?? InputDeviceProbe.current())
        continuation?.yield(
            .final(
                Piece(
                    text: piece.text, startMS: location.startMS, endMS: location.endMS,
                    confidence: piece.confidence, levelDBFS: level, input: input)))
    }

    private func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw AudioConverterError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// 同じ失敗が続く間は1度だけ伝える
    private func report(_ message: String) {
        guard message != lastReportedError else { return }
        lastReportedError = message
        continuation?.yield(.log(message))
    }
}
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter liveTranscription`
Expected: PASS（3件）。`liveTranscriptionGivesWallClockTimesToPieces`の発話の開始は、anchorから約1秒（先頭の無音の長さ）の位置になる

- [ ] **Step 5: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/notetaked/Pipeline/LiveTranscription.swift Tests/notetakedTests/LiveTranscriptionTests.swift
git commit -m "$(cat <<'MSG'
feat(serve): transcribe live audio from the raw audio files

LiveTranscription follows one source's .pcm every 100 ms, feeds the
transcriber, and gives each final piece wall-clock times from the
anchors, the input device from the device lines, and a level computed
from the piece's own samples. Stopping cancels the analyzer instead of
waiting to finalize, since the batch pass will write the finished
transcript.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 10: 取り込みの状態の変化をappへ伝える部品

serveは実状態のファイルを1秒ごとに読み、前回から変わった時だけappへ伝える。sourceの状態（取り込み中、再開待ちと理由、停止）が変わったら`status` event、固定した機器から既定の入力へ戻ったら`input_reset` eventを1回、新しい書き込みの失敗は`error` eventを1回ずつ送る。実状態が5秒更新されなければ、capture-daemonが動いていないとみなし、各sourceを「再開待ち（capture-daemonが応答していません）」にする。区切りの直後は、capture-daemonがまだ前の収録を書いているため、別のprefixの実状態は、5秒までは無視する。5秒たっても切り替わらなければ、各sourceを「再開待ち（capture-daemonが新しい収録へ切り替えていません）」にする。見張りはserveの寿命で1つ持ち、新しい収録を始めるたびに`beginRecording(keepingSnapshot:)`で失敗の記憶と食い違いの計時を消す（入力機器の固定が外れたかは収録をまたいで残るため、`input_reset`は区切りのたびには送り直さない。区切りでは前のsnapshotも残す）。

**Files:**
- Create: `Sources/NotetakeCore/Control/CaptureStatus.swift`
- Modify: `Sources/NotetakeCore/Control/Messages.swift`（`StatusEvent`に`capture`を足す）
- Test: `Tests/NotetakeCoreTests/CaptureStatusTests.swift`、`Tests/NotetakeCoreTests/MessagesTests.swift`（1件足す）

**Interfaces:**
- Consumes: `CaptureActualState`、`CaptureSourceState`（Task 2、3）
- Produces:
  - `struct CaptureStatus: Codable { var source: Source; var state: CaptureSourceState; var reason: String? }`
  - `StatusEvent.capture: [CaptureStatus]?`（JSONのkey`capture`。nilなら出さない）と、`init`の最後の引数`capture: [CaptureStatus]? = nil`
  - `struct CaptureActualWatcher`: `mutating beginRecording(keepingSnapshot: Bool)`、`mutating observe(_ actual: CaptureActualState?, prefix: String, sources: [Source], nowMS: Int64) -> Changes`。`Changes`は`snapshot: Snapshot?`（`statuses: [CaptureStatus]`、`micInput: InputDevice?`）、`inputReset: Bool`、`errors: [String]`。`static unresponsiveReason`、`static notSwitchedReason`、`static switchTimeoutMS`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/CaptureStatusTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

private func actual(
    prefix: String = "p", updated: Int64 = 10_000, mic: CaptureActualState.SourceStatus? = nil,
    system: CaptureActualState.SourceStatus? = nil
) -> CaptureActualState {
    CaptureActualState(pid: 1, prefix: prefix, sources: [mic, system].compactMap { $0 }, updated: updated)
}

@Test func actualWatcherReportsStatusOnlyWhenItChanges() {
    var watcher = CaptureActualWatcher()
    let recording = actual(mic: .init(source: .mic, state: .recording), system: .init(source: .system, state: .recording))

    let first = watcher.observe(recording, prefix: "p", sources: [.mic, .system], nowMS: 10_500)
    #expect(first.snapshot?.statuses == [
        CaptureStatus(source: .mic, state: .recording), CaptureStatus(source: .system, state: .recording),
    ])
    #expect(watcher.observe(recording, prefix: "p", sources: [.mic, .system], nowMS: 11_000).snapshot == nil)

    let retrying = actual(
        updated: 12_000, mic: .init(source: .mic, state: .recording),
        system: .init(source: .system, state: .retrying, reason: "The stream was stopped by the system"))
    let changed = watcher.observe(retrying, prefix: "p", sources: [.mic, .system], nowMS: 12_100)
    #expect(changed.snapshot?.statuses[1] == CaptureStatus(source: .system, state: .retrying, reason: "The stream was stopped by the system"))
}

@Test func actualWatcherSendsInputResetOncePerFallback() {
    var watcher = CaptureActualWatcher()
    let fellBack = actual(mic: .init(source: .mic, state: .recording, fellBackFromPinned: true))
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_000).inputReset)
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_500).inputReset == false)
    let restored = actual(mic: .init(source: .mic, state: .recording, fellBackFromPinned: false))
    #expect(watcher.observe(restored, prefix: "p", sources: [.mic], nowMS: 10_600).inputReset == false)
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_700).inputReset)
}

@Test func actualWatcherReportsEachNewErrorOnce() {
    var watcher = CaptureActualWatcher()
    let failing = actual(mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_000).errors == ["mic: 生音声を書けません"])
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_500).errors == [])
}

@Test func actualWatcherTreatsStaleOrMissingStateAsUnresponsive() {
    var watcher = CaptureActualWatcher()
    let stale = watcher.observe(actual(updated: 1_000), prefix: "p", sources: [.system], nowMS: 6_001)
    #expect(stale.snapshot?.statuses == [
        CaptureStatus(source: .system, state: .retrying, reason: CaptureActualWatcher.unresponsiveReason)
    ])
    #expect(watcher.observe(nil, prefix: "p", sources: [.system], nowMS: 7_000).snapshot == nil)
}

@Test func actualWatcherIgnoresStateOfAnotherRecording() {
    var watcher = CaptureActualWatcher()
    let other = actual(prefix: "old", mic: .init(source: .mic, state: .recording))
    #expect(watcher.observe(other, prefix: "new", sources: [.mic], nowMS: 10_000) == CaptureActualWatcher.Changes())
}

@Test func beginRecordingKeepsTheFallbackSoItIsNotSentAgain() {
    var watcher = CaptureActualWatcher()
    let fellBack = actual(mic: .init(source: .mic, state: .recording, fellBackFromPinned: true))
    #expect(watcher.observe(fellBack, prefix: "p", sources: [.mic], nowMS: 10_000).inputReset)

    watcher.beginRecording(keepingSnapshot: true)

    let next = actual(prefix: "q", mic: .init(source: .mic, state: .recording, fellBackFromPinned: true))
    #expect(watcher.observe(next, prefix: "q", sources: [.mic], nowMS: 10_500).inputReset == false)
}

@Test func beginRecordingForgetsReportedErrors() {
    var watcher = CaptureActualWatcher()
    let failing = actual(mic: .init(source: .mic, state: .recording, lastError: "生音声を書けません"))
    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_000).errors == ["mic: 生音声を書けません"])

    watcher.beginRecording(keepingSnapshot: true)

    #expect(watcher.observe(failing, prefix: "p", sources: [.mic], nowMS: 10_500).errors == ["mic: 生音声を書けません"])
}

@Test func beginRecordingDecidesWhetherTheFirstSnapshotIsSentAgain() {
    var watcher = CaptureActualWatcher()
    let recording = actual(mic: .init(source: .mic, state: .recording))
    _ = watcher.observe(recording, prefix: "p", sources: [.mic], nowMS: 10_000)

    watcher.beginRecording(keepingSnapshot: true)
    #expect(watcher.observe(recording, prefix: "p", sources: [.mic], nowMS: 10_500).snapshot == nil)

    watcher.beginRecording(keepingSnapshot: false)
    #expect(watcher.observe(recording, prefix: "p", sources: [.mic], nowMS: 11_000).snapshot != nil)
}

@Test func actualWatcherReportsADaemonThatDoesNotSwitchToTheNewRecording() {
    var watcher = CaptureActualWatcher()
    let old = actual(prefix: "old", updated: 10_000, mic: .init(source: .mic, state: .recording))
    let fresh = { (updated: Int64) in
        actual(prefix: "old", updated: updated, mic: .init(source: .mic, state: .recording))
    }
    #expect(watcher.observe(old, prefix: "new", sources: [.mic], nowMS: 10_000).snapshot == nil)
    #expect(watcher.observe(fresh(13_000), prefix: "new", sources: [.mic], nowMS: 13_000).snapshot == nil)

    let stuck = watcher.observe(fresh(15_000), prefix: "new", sources: [.mic], nowMS: 15_000)
    #expect(stuck.snapshot?.statuses == [
        CaptureStatus(source: .mic, state: .retrying, reason: CaptureActualWatcher.notSwitchedReason)
    ])
    #expect(watcher.observe(fresh(16_000), prefix: "new", sources: [.mic], nowMS: 16_000).snapshot == nil)

    let switched = actual(prefix: "new", updated: 17_000, mic: .init(source: .mic, state: .recording))
    #expect(watcher.observe(switched, prefix: "new", sources: [.mic], nowMS: 17_000).snapshot?.statuses == [
        CaptureStatus(source: .mic, state: .recording)
    ])
}

@Test func actualWatcherRestartsTheSwitchTimerForEachRecording() {
    var watcher = CaptureActualWatcher()
    let old = { (updated: Int64) in
        actual(prefix: "old", updated: updated, mic: .init(source: .mic, state: .recording))
    }
    _ = watcher.observe(old(10_000), prefix: "new", sources: [.mic], nowMS: 10_000)

    watcher.beginRecording(keepingSnapshot: true)

    #expect(watcher.observe(old(14_000), prefix: "newer", sources: [.mic], nowMS: 14_000).snapshot == nil)
    #expect(watcher.observe(old(18_000), prefix: "newer", sources: [.mic], nowMS: 18_000).snapshot == nil)
    #expect(watcher.observe(old(19_000), prefix: "newer", sources: [.mic], nowMS: 19_000).snapshot != nil)
}
```

`Tests/NotetakeCoreTests/MessagesTests.swift`の末尾に足す:

```swift
@Test func statusEventCarriesCaptureStatesOnlyWhenPresent() throws {
    let recording = StatusEvent(
        recording: true, prefix: "2026-10-03_100000", sources: [.mic, .system], outputDirectory: "/tmp",
        capture: [
            CaptureStatus(source: .mic, state: .recording),
            CaptureStatus(source: .system, state: .retrying, reason: "The stream was stopped by the system"),
        ])
    let line = try Event.status(recording).encodedLine()
    #expect(line.contains("\"capture\":[{"))
    #expect(try Event.decode(line: line) == .status(recording))

    let stopped = try Event.status(StatusEvent(recording: false, sources: [], outputDirectory: "/tmp")).encodedLine()
    #expect(!stopped.contains("capture"))
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter 'actualWatcher|statusEventCarriesCapture'`
Expected: buildが`cannot find 'CaptureActualWatcher' in scope`などで失敗する

- [ ] **Step 3: 実装する**

`Sources/NotetakeCore/Control/CaptureStatus.swift`:

```swift
import Foundation

/// statusイベントでappへ伝える、sourceごとの取り込みの状態
public struct CaptureStatus: Codable, Sendable, Equatable {
    public var source: Source
    public var state: CaptureSourceState
    /// `retrying`の理由
    public var reason: String?

    public init(source: Source, state: CaptureSourceState, reason: String? = nil) {
        self.source = source
        self.state = state
        self.reason = reason
    }
}

/// serveが実状態のファイルを読むたびに、appへ伝える変化を求める
public struct CaptureActualWatcher: Sendable {
    /// capture-daemonは1秒ごとに書くため、これより古い実状態はcapture-daemonが動いていないと見なす
    public static let staleAfterMS: Int64 = 5_000
    public static let unresponsiveReason = "capture-daemonが応答していません"
    /// 実状態のprefixが収録中の収録に切り替わらないまま、この時間が過ぎたら切り替わっていないと見なす
    public static let switchTimeoutMS: Int64 = 5_000
    public static let notSwitchedReason = "capture-daemonが新しい収録へ切り替えていません"

    public struct Snapshot: Equatable, Sendable {
        public var statuses: [CaptureStatus]
        public var micInput: InputDevice?
    }

    public struct Changes: Equatable, Sendable {
        /// 前回から変わった時だけ入る
        public var snapshot: Snapshot?
        /// 固定した入力機器から既定の入力へ戻った
        public var inputReset = false
        /// sourceごとの新しい書き込みや変換の失敗
        public var errors: [String] = []
    }

    private var last: Snapshot?
    private var fellBack = false
    private var reportedErrors: [Source: String] = [:]
    /// 実状態のprefixが収録中の収録と食い違い始めた時刻
    private var mismatchSince: Int64?

    public init() {}

    /// 新しい収録を始める。失敗の記憶と食い違いの計時は消す。入力機器の固定が外れたかは収録をまたいで続くため残す。
    /// `keepingSnapshot`がtrueなら（区切り）前回のsnapshotを残し、同じ表示を重ねて伝えない。
    /// falseなら（開始と引き継ぎ）最初の実状態を必ず伝える
    public mutating func beginRecording(keepingSnapshot: Bool) {
        reportedErrors = [:]
        mismatchSince = nil
        if !keepingSnapshot {
            last = nil
        }
    }

    /// `prefix`は収録中の収録。別の収録を書いている実状態は、切り替えの途中なので`switchTimeoutMS`の間は無視する。
    /// それを過ぎても切り替わらなければ、各sourceを「再開待ち」にする
    public mutating func observe(
        _ actual: CaptureActualState?, prefix: String, sources: [Source], nowMS: Int64
    ) -> Changes {
        var changes = Changes()
        let snapshot: Snapshot
        if let actual, nowMS - actual.updated <= Self.staleAfterMS {
            if actual.prefix != prefix {
                // 区切りの直後は、capture-daemonが書き込み先を切り替えるまでの間だけ食い違う
                let since = mismatchSince ?? nowMS
                mismatchSince = since
                guard nowMS - since >= Self.switchTimeoutMS else { return changes }
                return onlyChanges(
                    replacing: Snapshot(
                        statuses: sources.map {
                            CaptureStatus(source: $0, state: .retrying, reason: Self.notSwitchedReason)
                        },
                        micInput: last?.micInput))
            }
            mismatchSince = nil
            let mic = actual.sources.first { $0.source == .mic }
            snapshot = Snapshot(
                statuses: sources.map { source in
                    let status = actual.sources.first { $0.source == source }
                    return CaptureStatus(source: source, state: status?.state ?? .off, reason: status?.reason)
                },
                micInput: mic?.input)
            let micFellBack = mic?.fellBackFromPinned ?? false
            changes.inputReset = micFellBack && !fellBack
            fellBack = micFellBack
            for status in actual.sources {
                guard let error = status.lastError, reportedErrors[status.source] != error else { continue }
                reportedErrors[status.source] = error
                changes.errors.append("\(status.source.rawValue): \(error)")
            }
        } else {
            mismatchSince = nil
            snapshot = Snapshot(
                statuses: sources.map {
                    CaptureStatus(source: $0, state: .retrying, reason: Self.unresponsiveReason)
                },
                micInput: last?.micInput)
        }
        if snapshot != last {
            changes.snapshot = snapshot
            last = snapshot
        }
        return changes
    }

    private mutating func onlyChanges(replacing snapshot: Snapshot) -> Changes {
        var changes = Changes()
        if snapshot != last {
            changes.snapshot = snapshot
            last = snapshot
        }
        return changes
    }
}
```

`Sources/NotetakeCore/Control/Messages.swift`の`StatusEvent`で、`outputDirectory`の宣言とCodingKeysと`init`を置き換える:

```swift
    public var outputDirectory: String  // key: output_directory
    public var capture: [CaptureStatus]?  // 収録中のsourceごとの取り込みの状態

    enum CodingKeys: String, CodingKey {
        case recording
        case prefix
        case sources
        case inputName = "input_name"
        case inputSpatial = "input_spatial"
        case outputDirectory = "output_directory"
        case capture
    }

    public init(
        recording: Bool,
        prefix: String? = nil,
        sources: [Source],
        inputName: String? = nil,
        inputSpatial: Bool? = nil,
        outputDirectory: String,
        capture: [CaptureStatus]? = nil
    ) {
        self.recording = recording
        self.prefix = prefix
        self.sources = sources
        self.inputName = inputName
        self.inputSpatial = inputSpatial
        self.outputDirectory = outputDirectory
        self.capture = capture
    }
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'actualWatcher|statusEvent|eventRoundTrip'`
Expected: PASS

- [ ] **Step 5: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 6: commit（controller）**

```bash
git add Sources/NotetakeCore/Control/CaptureStatus.swift Sources/NotetakeCore/Control/Messages.swift Tests/NotetakeCoreTests/CaptureStatusTests.swift Tests/NotetakeCoreTests/MessagesTests.swift
git commit -m "$(cat <<'MSG'
feat(core): tell the app how each source is capturing

StatusEvent carries a capture state per source. CaptureActualWatcher
compares each read of capture-actual.json with the last one and reports
changed states, a single input_reset when the pinned mic falls back, new
write errors once each, and an unresponsive capture-daemon when the file
stops updating for five seconds.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 11: serveを望む状態とライブの文字起こしで組み直す

`ServeSession`の収録の部分を置き換える。peerの部分（`// MARK: - peer: pairing / listener lifecycle`以降）は、過去の収録へ追記した時の`final.md`の作り方の2行だけを変える。

- **開始**: 出力ファイルへ収録とMacの記録を書き、生音声ディレクトリへ`session.json`を書き、望む状態を書いてから、sourceごとに`LiveTranscription`を始める。全sourceの文字起こしを始め、状態（保存先、Reconciler、seq）を整えた後で、結果の受け取りを始める（先に受け取ると、確定した発話を保存先が無いまま落とす）。どこかで失敗したら、望む状態を停止へ戻す。停止へ戻す書き込みに失敗したら、書けるまで実状態を読む1秒ごとの繰り返しで書き直す
- **停止**: ライブの文字起こしを打ち切り、ここまでの発話で`final.md`を書いて閉じ、望む状態を停止にする
- **区切り**: 停止と同じく前の収録を閉じ、新しい収録を始める。望む状態のprefixだけが変わるため、capture-daemonは取り込みを止めずに書き込み先を切り替える。取り込みの状態と入力機器は引き継ぎ、停止と開始の時だけ消す
- **引き継ぎ**: 起動時に望む状態のファイルが収録中を示していれば、その収録の`timed.jsonl`を`Reconciler.restore`で畳み込み、`.pcm`の現在の末尾から文字起こしを始める。`log` eventで`resumed <prefix>`を出す。`timed.jsonl`は壊れたbyteがあっても読める行で引き継ぎ、読めなければ望む状態を停止にする。生音声のディレクトリに`session.json`が無ければ書き直す。再開マーカー（`current-session.json`）は使わない
- **実状態**: 最初の収録で、実状態を1秒ごとに読む繰り返しを始め、`CaptureActualWatcher`の結果を`status`・`input_reset`・`error` eventで送る。`status`の`input_name`と`input_spatial`は、実状態が伝えるmicの入力機器にする。実状態を解釈できない時は、capture-daemonが応答していない時と同じに扱い、原因を`log` eventで1度だけ出す。文字起こしが途中で止まったら`error` eventで伝える
- 収録中の話者分離（`Diarizer`、`SpeakerRegistry`、`ProfileNameAnnouncer`、大域の話者profile）と、checkpoint、命令とeventのファイルを使わなくなる。`rename_speaker`は記録を足して表示を変えるだけにする（段階2で収録ごとの命名に作り直す）
- `ServeCommand`から`--diarize`と話者分離のmodelの準備を外す（appはこの引数を渡していない）。起動の終わりに`log` eventで`serve ready`を出す。appの起動確認（`launch.sh`）がこれを待つ

この時点では使われなくなった型（`CaptureStream`など）がまだ残る。Task 12で消す。

**Files:**
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift`、`Sources/NotetakeCore/Session/SessionStore.swift`
- Replace: `Sources/notetaked/Commands/ServeCommand.swift`
- Create: `.claude/skills/daemon-realtest/scripts/cli-cycle.sh`、`.claude/skills/daemon-realtest/scripts/cli-cycle-report.py`
- Test: `Tests/NotetakeCoreTests/SessionStoreTests.swift`（3件足す）

**Interfaces:**
- Consumes: `LiveTranscription`（Task 9）、`CaptureActualWatcher`・`CaptureStatus`・`StatusEvent.capture`（Task 10）、`Reconciler.restore`（Task 8）、`CaptureDesiredState`・`CaptureActualState`（Task 3）、`CaptureSessionInfo`・`CaptureSessionPaths.sessionInfoURL`（Task 2）、`JSONFile`（Task 1）
- Produces: `SessionStore.init(directory: URL, prefix: String)`（追記の前に、改行で終わっていない最後の行を改行で閉じる）。`ServeSession.init(outputDirectory:owner:sourceOption:locale:control:device:inputDeviceUID:)`、`ServeSession.resumeIfRecording() async`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/SessionStoreTests.swift`の`urlsUsePrefix`の後に足す:

```swift
@Test func storeOpenedByPrefixUsesThatPrefix() {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = SessionStore(directory: dir, prefix: "2026-10-03_100000")

    #expect(store.prefix == "2026-10-03_100000")
    #expect(store.timedURL.lastPathComponent == "2026-10-03_100000.timed.jsonl")
}

@Test func appendClosesALastLineThatDoesNotEndWithNewline() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir, prefix: "2026-10-03_100000")
    try Data(#"{"type":"session","id":"s"#.utf8).write(to: store.timedURL)

    try await store.append(.session(SessionRecord(id: "s1", started: 0, owner: "bash")))
    await store.close()

    let lines = try String(contentsOf: store.timedURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    #expect(NDJSON.decodeAll(try String(contentsOf: store.timedURL, encoding: .utf8)).count == 1)
}

@Test func appendKeepsALastLineThatEndsWithNewline() async throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir, prefix: "2026-10-03_100000")

    try await store.append(.session(SessionRecord(id: "s1", started: 0, owner: "bash")))
    await store.close()
    try await store.append(.session(SessionRecord(id: "s2", started: 1, owner: "bash")))
    await store.close()

    let text = try String(contentsOf: store.timedURL, encoding: .utf8)
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
    #expect(NDJSON.decodeAll(text).count == 2)
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter storeOpenedByPrefix`
Expected: buildが`extra argument 'prefix' in call`などで失敗する

- [ ] **Step 3: SessionStoreをprefixで開けるようにする**

`Sources/NotetakeCore/Session/SessionStore.swift`の`init(directory:start:timeZone:)`を置き換える:

```swift
    public init(directory: URL, prefix: String) {
        self.prefix = prefix
        self.liveURL = directory.appendingPathComponent("\(prefix).live.txt")
        self.timedURL = directory.appendingPathComponent("\(prefix).timed.jsonl")
        self.finalURL = directory.appendingPathComponent("\(prefix).final.md")
        self.speakersURL = directory.appendingPathComponent("\(prefix).speakers.json")
    }

    public init(directory: URL, start: Date, timeZone: TimeZone = .current) {
        self.init(directory: directory, prefix: SessionStore.prefix(for: start, timeZone: timeZone))
    }
```

同じファイルの`openHandle`で、開くハンドルを`FileHandle(forUpdating:)`にし、末尾へ移動する代わりに、改行で終わっていない最後の行を閉じる関数を呼ぶ。`seekToEnd()`の行を置き換える:

```swift
        let handle = try FileHandle(forUpdating: url)
        try closeUnterminatedLastLine(of: handle)
        cached = handle
        return handle
```

`openHandle`の前に足す:

```swift
    /// 書き手が落ちて改行で終わっていない最後の行は、その行だけが壊れた行になるよう改行で閉じてから追記する。
    /// 末尾へ移動して返す
    private func closeUnterminatedLastLine(of handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        let last = try handle.read(upToCount: 1)
        try handle.seekToEnd()
        if last != Data([0x0A]) {
            try handle.write(contentsOf: Data([0x0A]))
        }
    }
```

- [ ] **Step 4: ServeSessionの収録の部分を置き換える**

`Sources/notetaked/Pipeline/ServeSession.swift`の先頭から`    // MARK: - peer: pairing / listener lifecycle`の直前までを、次の内容で置き換える:

```swift
#if canImport(Speech)
import Foundation
import NotetakeCore

/// serveの収録の状態（出力ファイル、Reconciler、ライブの文字起こし、capture-daemonの状態）を持ち、
/// stdinのコマンド、文字起こしの結果、peerからの受信が競合しないよう1つのactorへ直列化する
@available(macOS 26, iOS 26, *)
actor ServeSession {
    enum SourceOption: String {
        case mic, system, both

        var sources: [(source: Source, owner: (_ configuredOwner: String) -> String)] {
            switch self {
            case .mic:
                return [(.mic, { $0 })]
            case .system:
                return [(.system, { _ in "リモート" })]
            case .both:
                return [(.mic, { $0 }), (.system, { _ in "リモート" })]
            }
        }
    }

    private struct LiveStream {
        let source: Source
        let transcription: LiveTranscription
        let consumer: Task<Void, Never>
    }

    /// 状態を整える前の、始めたばかりのライブの文字起こし
    private struct StartedTranscription {
        let source: Source
        let owner: String
        let transcription: LiveTranscription
        let outputs: AsyncStream<LiveTranscription.Output>
    }

    /// peer接続1本ぶんの状態（hello情報・clock offset・ping往復管理）
    private struct PeerState {
        var hello: HelloMessage?
        var offsetSamples: [ClockOffsetSample] = []
        var pingID: Int = 0
        var pingSent: [Int: Int64] = [:]
        /// 接続直後の即時5回 + 以後60秒ごとのping送信を担うTask。切断時にcancelする
        var pingTask: Task<Void, Never>?
    }

    private let outputDirectory: URL
    private let owner: String
    private let sourceOption: SourceOption
    private let locale: Locale
    private let control: StdioControl
    private let device: DeviceIdentity
    /// micを固定したい入力機器のUID。nilなら既定の入力を使う
    private let inputDeviceUID: String?

    private var store: SessionStore?
    private var reconciler = Reconciler()
    private var seq = 0
    private var live: [LiveStream] = []
    private var recording = false
    /// 直前に使ったprefix。同じ秒の中で開始と区切りが重なってもprefixが衝突しないよう、開始時刻をずらすのに使う
    private var lastPrefix: String?
    /// serveの寿命で1つ。収録ごとの記憶は`beginRecording`で消す
    private var captureWatcher = CaptureActualWatcher()
    /// 望む状態を停止へ書けなかった。書けるまで1秒ごとに書き直す
    private var desiredStopPending = false
    /// 直前に読めなかった実状態の失敗。同じ失敗はlogへ1度だけ出す
    private var lastActualReadError: String?
    private var captureStatuses: [CaptureStatus] = []
    /// capture-daemonが実状態で伝えるmicの入力機器
    private var micInput: InputDevice?
    private var captureWatchTask: Task<Void, Never>?

    // MARK: - peer (iPhone/Watch)

    private var peerListener: PeerListener?
    private var peerStates: [PeerConnectionID: PeerState] = [:]
    /// 出力ディレクトリの`*.timed.jsonl`から作った収録一覧。start/stop/rotateのたびに
    /// 更新する（受信seg以外のタイミングでは変わらないため常時再scanはしない）。
    /// 進行中の収録は`endMS == nil`にして`SessionMatcher`へ渡す
    private var sessions: [SessionSpan] = []
    /// device単位の受信済み最大seq（`ReceivedCursor`のin-memory mirror）
    private var receivedCursors: [String: Int] = [:]
    private let receivedCursorStore = ReceivedCursor.default()
    /// 進行中の収録で既にDeviceRecordを書いたdevice id集合。新しいprefixで開始するたびリセットする
    private var recordedPeerDevices: Set<String> = []

    init(
        outputDirectory: URL, owner: String, sourceOption: SourceOption, locale: Locale,
        control: StdioControl, device: DeviceIdentity, inputDeviceUID: String? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.owner = owner
        self.sourceOption = sourceOption
        self.locale = locale
        self.control = control
        self.device = device
        self.inputDeviceUID = inputDeviceUID
        self.sessions = SessionIndex.scan(directory: outputDirectory)
    }

    /// serveが再起動する前から収録が続いていれば、同じ収録を引き継ぐ。収録中かどうかは望む状態のファイルで判断する。
    /// 再起動の間の音声はライブの表示には出ないが、生音声には残る
    func resumeIfRecording() async {
        let desired: CaptureDesiredState?
        do {
            desired = try JSONFile.read(CaptureDesiredState.self, from: CaptureStatePaths.captureDesiredURL)
        } catch {
            await control.send(.error("failed to read capture desired state: \(error)"))
            return
        }
        guard let recording = desired?.recording else { return }
        let store = SessionStore(directory: outputDirectory, prefix: recording.prefix)
        let text: String
        do {
            // 電源断などで壊れたbyteがあっても、読める行で引き継ぐ
            text = String(decoding: try Data(contentsOf: store.timedURL), as: UTF8.self)
            try restoreSessionInfoIfMissing(sessionDirectory: URL(fileURLWithPath: recording.directory))
        } catch {
            await control.send(.error("failed to resume \(recording.prefix): \(error)"))
            await writeDesiredStopped()
            return
        }
        let restored = Reconciler.restore(from: NDJSON.decodeAll(text), device: device.id)
        guard
            await beginLive(
                store: store, sessionDirectory: URL(fileURLWithPath: recording.directory), startAtEnd: true,
                keepingCapture: false, reconciler: restored.reconciler, seq: restored.lastSeq)
        else {
            await writeDesiredStopped()
            return
        }
        await control.send(.status(statusEvent()))
        await control.send(.log("resumed \(recording.prefix)"))
    }

    /// 再起動の前に生音声のディレクトリが消えていても、段階2が出力先を辿れるよう`session.json`を書き直す
    private func restoreSessionInfoIfMissing(sessionDirectory: URL) throws {
        let url = CaptureSessionPaths.sessionInfoURL(sessionDirectory: sessionDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try JSONFile.write(
            CaptureSessionInfo(
                outputDirectory: outputDirectory.path, device: device.id, deviceName: device.name, owner: owner),
            to: url)
    }

    func handle(_ command: Command) async {
        switch command {
        case .start:
            await start()
        case .stop:
            await stop()
        case .renameSpeaker(let id, let name):
            await renameSpeaker(id: id, name: name)
        case .rotate:
            await rotate()
        case .pairCode(let code):
            await setPairingCode(code)
        case .quit:
            await quit()
        }
    }

    // MARK: - start

    private func start() async {
        guard !recording else {
            await control.send(.error("already recording"))
            return
        }
        if await startNewRecording(keepingCapture: false) {
            await control.send(.status(statusEvent()))
        }
    }

    /// 新しい収録を始める。出力ファイルへ収録とMacの記録を書き、生音声ディレクトリへ`session.json`を書いてから、
    /// 望む状態でcapture-daemonへ書き込み先を伝え、ライブの文字起こしを始める
    /// `keepingCapture`は区切りの時だけtrue。取り込みの状態と入力機器を引き継ぎ、表示が途切れないようにする
    private func startNewRecording(keepingCapture: Bool) async -> Bool {
        var date = Date()
        while SessionStore.prefix(for: date, timeZone: .current) == lastPrefix {
            date.addTimeInterval(1)
        }
        let store = SessionStore(directory: outputDirectory, start: date)
        let sessionDirectory = CaptureSessionPaths.sessionDirectory(prefix: store.prefix)
        do {
            try await store.append(
                .session(SessionRecord(id: store.prefix, started: Self.ms(date), owner: owner)))
            try await store.append(
                .device(
                    DeviceRecord(
                        device: device.id, deviceName: device.name, owner: owner, platform: .mac, offsetMS: 0)))
            try JSONFile.write(
                CaptureSessionInfo(
                    outputDirectory: outputDirectory.path, device: device.id, deviceName: device.name,
                    owner: owner),
                to: CaptureSessionPaths.sessionInfoURL(sessionDirectory: sessionDirectory))
            // 停止の書き直しが、ここで書く収録中を上書きしないよう、書く直前に取り下げる
            desiredStopPending = false
            try JSONFile.write(
                desiredState(.init(prefix: store.prefix, directory: sessionDirectory.path)),
                to: CaptureStatePaths.captureDesiredURL)
        } catch {
            await store.close()
            await control.send(.error("failed to start session: \(error)"))
            await writeDesiredStopped()
            return false
        }
        guard
            await beginLive(
                store: store, sessionDirectory: sessionDirectory, startAtEnd: false, keepingCapture: keepingCapture,
                reconciler: Reconciler(), seq: 0)
        else {
            await writeDesiredStopped()
            return false
        }
        return true
    }

    /// sourceごとにライブの文字起こしを始め、収録中の状態へ移る。失敗したら始めた分を止めて`false`を返す。
    /// 先に全sourceの文字起こしを始め、状態を整えてから結果の受け取りを始める。
    /// 受け取りが先に動くと、確定した発話を保存先が無いまま落とす
    private func beginLive(
        store: SessionStore, sessionDirectory: URL, startAtEnd: Bool, keepingCapture: Bool, reconciler: Reconciler,
        seq: Int
    ) async -> Bool {
        var started: [StartedTranscription] = []
        for (source, ownerFor) in sourceOption.sources {
            do {
                let transcription = try await LiveTranscription(
                    source: source, sessionDirectory: sessionDirectory, locale: locale, startAtEnd: startAtEnd)
                let outputs = try await transcription.start()
                started.append(
                    StartedTranscription(
                        source: source, owner: ownerFor(owner), transcription: transcription, outputs: outputs))
            } catch {
                for item in started {
                    await item.transcription.stop()
                }
                await store.close()
                await control.send(.error("failed to start live transcription: \(error)"))
                return false
            }
        }
        self.store = store
        self.reconciler = reconciler
        self.seq = seq
        recording = true
        lastPrefix = store.prefix
        recordedPeerDevices = []
        if !keepingCapture {
            captureStatuses = []
            micInput = nil
        }
        captureWatcher.beginRecording(keepingSnapshot: keepingCapture)
        live = started.map { item in
            let source = item.source
            let streamOwner = item.owner
            let outputs = item.outputs
            let consumer = Task { [weak self] in
                for await output in outputs {
                    await self?.handle(output, source: source, owner: streamOwner)
                }
            }
            return LiveStream(source: source, transcription: item.transcription, consumer: consumer)
        }
        refreshSessions()
        ensureCaptureWatch()
        return true
    }

    // MARK: - live transcription

    private func handle(_ output: LiveTranscription.Output, source: Source, owner: String) async {
        switch output {
        case .volatile(let text):
            await control.send(.volatile(source: source, text: text))
        case .final(let piece):
            await handleFinal(piece, source: source, owner: owner)
        case .log(let message):
            await control.send(.log(message))
        case .error(let message):
            await control.send(.error(message))
        }
    }

    private func handleFinal(_ piece: LiveTranscription.Piece, source: Source, owner: String) async {
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let store else {
            await control.send(.log("収録していないため発話を保存できません: \(piece.text)"))
            return
        }
        seq += 1
        let segment = Segment(
            id: UUID(),
            session: store.prefix,
            seq: seq,
            device: device.id,
            deviceName: device.name,
            owner: owner,
            platform: .mac,
            source: source,
            input: piece.input,
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence,
            levelDBFS: piece.levelDBFS,
            clockOffsetMS: 0,
            receivedAt: Self.ms(Date()))
        do {
            try await store.append(.segment(segment))
        } catch {
            await control.send(.error("failed to append segment: \(error)"))
            return
        }
        for utterance in reconciler.apply(.segment(segment)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - capture-daemon

    private func desiredState(_ recording: CaptureDesiredState.Recording?) -> CaptureDesiredState {
        CaptureDesiredState(
            recording: recording, sources: sourceOption.sources.map(\.source), pinnedInputUID: inputDeviceUID)
    }

    /// capture-daemonへ取り込みを止めるよう伝える
    /// 書けなければ、書けるまで実状態を読む繰り返しで書き直す
    private func writeDesiredStopped() async {
        do {
            try JSONFile.write(desiredState(nil), to: CaptureStatePaths.captureDesiredURL)
            desiredStopPending = false
        } catch {
            desiredStopPending = true
            ensureCaptureWatch()
            await control.send(.error("failed to write capture desired state: \(error)"))
        }
    }

    private func retryDesiredStopped() async {
        do {
            try JSONFile.write(desiredState(nil), to: CaptureStatePaths.captureDesiredURL)
            desiredStopPending = false
            await control.send(.log("capture desired stateを停止へ書き直しました"))
        } catch {
            // 失敗は書いた時に伝えてある。書けるまで1秒ごとに続ける
        }
    }

    /// 実状態を1秒ごとに読む処理を、まだ動いていなければ始める。
    /// actorの`init`ではselfを捕まえるTaskを作れないため、最初の収録で始める
    private func ensureCaptureWatch() {
        guard captureWatchTask == nil else { return }
        captureWatchTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollCaptureActual()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollCaptureActual() async {
        guard recording, let prefix = store?.prefix else {
            if desiredStopPending {
                await retryDesiredStopped()
            }
            return
        }
        let actual: CaptureActualState?
        do {
            actual = try JSONFile.read(CaptureActualState.self, from: CaptureStatePaths.captureActualURL)
            lastActualReadError = nil
        } catch {
            // 解釈できない実状態は、capture-daemonが応答していない時と同じに扱う。原因は1度だけlogへ出す
            actual = nil
            let message = "実状態を読めません: \(error)"
            if message != lastActualReadError {
                lastActualReadError = message
                await control.send(.log(message))
            }
        }
        let changes = captureWatcher.observe(
            actual, prefix: prefix, sources: sourceOption.sources.map(\.source), nowMS: Self.ms(Date()))
        if let snapshot = changes.snapshot {
            captureStatuses = snapshot.statuses
            micInput = snapshot.micInput
            await control.send(.status(statusEvent()))
        }
        if changes.inputReset {
            await control.send(.inputReset)
        }
        for message in changes.errors {
            await control.send(.error(message))
        }
    }

    private func statusEvent() -> StatusEvent {
        guard recording, let store else {
            return StatusEvent(recording: false, sources: [], outputDirectory: outputDirectory.path)
        }
        return StatusEvent(
            recording: true, prefix: store.prefix, sources: sourceOption.sources.map(\.source),
            inputName: micInput?.name, inputSpatial: micInput?.spatial, outputDirectory: outputDirectory.path,
            capture: captureStatuses.isEmpty ? nil : captureStatuses)
    }

    // MARK: - rename_speaker

    private func renameSpeaker(id: String, name: String) async {
        guard recording, let store else {
            await control.send(.error("not recording"))
            return
        }
        let rename = SpeakerNameRecord(speaker: id, name: name)
        do {
            try await store.append(.speakerName(rename))
        } catch {
            await control.send(.error("failed to rename speaker: \(error)"))
            return
        }
        for utterance in reconciler.apply(.speakerName(rename)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - stop

    private func stop() async {
        guard recording else {
            await control.send(.error("not recording"))
            return
        }
        await finishRecording()
        captureStatuses = []
        micInput = nil
        await writeDesiredStopped()
        await control.send(.status(statusEvent()))
    }

    /// ライブの文字起こしを打ち切り、ここまでの発話で`final.md`を書いて収録を閉じる。
    /// capture-daemonへの指示は呼び出し側が行う
    private func finishRecording() async {
        guard let store else { return }
        for stream in live {
            await stream.transcription.stop()
            await stream.consumer.value
        }
        live = []
        do {
            try await store.writeFinal(TranscriptRenderer.markdown(reconciler.utterances, timeZone: .current))
        } catch {
            await control.send(.error("failed to write final: \(error)"))
        }
        await store.close()
        self.store = nil
        recording = false
        refreshSessions()
    }

    // MARK: - rotate

    /// 取り込みを止めずに新しい収録へ切り替える。望む状態の書き換えで、capture-daemonは書き込み先だけを切り替える。
    /// 中間の`recording:false`のstatusは出さない
    private func rotate() async {
        guard recording, let oldPrefix = store?.prefix else {
            await control.send(.error("not recording"))
            return
        }
        await finishRecording()
        if await startNewRecording(keepingCapture: true), let store {
            await control.send(.status(statusEvent()))
            await control.send(.log("rotated \(oldPrefix) -> \(store.prefix)"))
        } else {
            captureStatuses = []
            micInput = nil
            await control.send(.status(statusEvent()))
        }
    }

    // MARK: - quit

    private func quit() async {
        captureWatchTask?.cancel()
        if recording {
            await stop()
        }
        if let peerListener {
            for state in peerStates.values {
                state.pingTask?.cancel()
            }
            peerStates.removeAll()
            await peerListener.stop()
            self.peerListener = nil
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
```

同じファイルの`appendToPastSession(prefix:segment:)`の中を置き換える。前:

```swift
            let text = try String(contentsOf: timedURL, encoding: .utf8)
            var reconciler = Reconciler()
            for record in NDJSON.decodeAll(text) {
                reconciler.apply(record)
            }
            let utterances = reconciler.resolveFallbackSpeakers()
            let markdown = TranscriptRenderer.markdown(utterances, timeZone: .current)
```

後:

```swift
            let text = try String(contentsOf: timedURL, encoding: .utf8)
            let markdown = TranscriptRenderer.markdown(Reconciler.fold(NDJSON.decodeAll(text)), timeZone: .current)
```

- [ ] **Step 5: ServeCommandを置き換える**

`Sources/notetaked/Commands/ServeCommand.swift`を次の内容で置き換える:

```swift
import ArgumentParser
import Foundation
import NotetakeCore

#if canImport(Speech)
import Speech
#endif

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the resident transcription daemon, controlled over stdin/stdout NDJSON"
    )

    @Option(name: .customLong("output"), help: "Directory to write session files into")
    var outputDirectory: String

    @Option(name: .customLong("owner"), help: "Owner label for the local (mic) speaker")
    var owner: String

    @Option(name: .customLong("source"), help: "Audio source: mic, system, or both")
    var source: String = "mic"

    @Option(name: .customLong("locale"), help: "BCP-47 locale to transcribe with")
    var locale: String = "ja-JP"

    @Option(name: .customLong("control"), help: "Control channel: stdio")
    var control: String = "stdio"

    @Flag(name: .customLong("start"), help: "Start recording immediately on launch")
    var startImmediately = false

    @Option(
        name: .customLong("pair-code"),
        help: "6-digit pairing code: starts the iPhone/Watch peer listener on launch")
    var pairCode: String?

    @Option(
        name: .customLong("input-device"),
        help: "Pin mic input to this device UID if connected (optional; falls back to OS default)")
    var inputDeviceUID: String?

    func run() async throws {
        #if canImport(Speech)
        guard #available(macOS 26, iOS 26, *) else {
            throw ValidationError("serve requires macOS 26 or later")
        }
        guard control == "stdio" else {
            throw ValidationError("--control must be stdio")
        }
        guard let sourceOption = ServeSession.SourceOption(rawValue: source) else {
            throw ValidationError("--source must be mic, system, or both")
        }
        try await runServe(sourceOption: sourceOption)
        #else
        throw ValidationError("Speech framework is unavailable on this platform")
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26, iOS 26, *)
    private func runServe(sourceOption: ServeSession.SourceOption) async throws {
        let outputURL = URL(fileURLWithPath: outputDirectory)
        try FileManager.default.createDirectory(
            at: outputURL, withIntermediateDirectories: true)

        // 音声の資産の確認には数秒かかることがある。その間にappがハングと判定しないよう、先に心拍を書く
        try? Heartbeat.write(to: CaptureStatePaths.processHeartbeatURL)

        let selectedLocale = Locale(identifier: locale)
        try await Transcriber.ensureAssets(locale: selectedLocale)

        let stdioControl = StdioControl()
        let session = ServeSession(
            outputDirectory: outputURL, owner: owner, sourceOption: sourceOption,
            locale: selectedLocale, control: stdioControl, device: DeviceIdentity.load(),
            inputDeviceUID: inputDeviceUID)

        await stdioControl.send(
            .status(StatusEvent(recording: false, sources: [], outputDirectory: outputURL.path)))

        await session.resumeIfRecording()

        if let pairCode {
            await session.handle(.pairCode(pairCode))
        }

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            Task {
                await session.handle(.quit)
                Foundation.exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        sigintSource.resume()

        // アプリ側がterminate()の締め切りでProcess.terminate()（SIGTERM）に切り替えた場合も、
        // SIGINTと同じ経路でcleanにstopしてからexitする
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            Task {
                await session.handle(.quit)
                Foundation.exit(0)
            }
        }
        signal(SIGTERM, SIG_IGN)
        sigtermSource.resume()

        let heartbeatTask = Task {
            while !Task.isCancelled {
                try? Heartbeat.write(to: CaptureStatePaths.processHeartbeatURL)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        defer { heartbeatTask.cancel() }

        await stdioControl.send(.log("serve ready"))

        if startImmediately {
            await session.handle(.start)
        }

        for await command in await stdioControl.commands() {
            if case .quit = command {
                await session.handle(.quit)
                return
            }
            await session.handle(command)
        }

        // stdin reached EOF: behave as quit
        await session.handle(.quit)
    }
    #endif
}
```

- [ ] **Step 6: 通ることを確かめる**

Run: `swift test --filter 'storeOpenedByPrefix|urlsUsePrefix|appendClosesALastLine|appendKeepsALastLine'`
Expected: PASS

- [ ] **Step 7: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`

- [ ] **Step 8: CLIで一巡するscriptを置く**

`.claude/skills/daemon-realtest/scripts/cli-cycle.sh`:

```bash
#!/bin/bash
# capture-daemonとserveをCLIで起動し、開始、発話、区切り、serveの強制終了と再開、
# capture-daemonの強制終了と再開、停止を一巡する。判定はcli-cycle-report.pyで行う。
# usage: cli-cycle.sh <出力先directory>（repoのrootで、make daemonの完了後に実行する）
set -uo pipefail
D="$1"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
# appと同じ状態ファイルを使うため、appやほかのnotetakedが動いている時は始めない
if pgrep -x Notetake > /dev/null || pgrep -f 'notetaked (serve|capture-daemon)' > /dev/null; then
  echo "Notetake.appかnotetakedが動いています。止めてから実行してください" >&2
  exit 1
fi
[ -x "$BIN" ] || { echo "$BINがありません。make daemonの後に実行してください" >&2; exit 1; }
# 前の結果が残っていると、待ちと判定が前の結果で通ってしまう
if [ -n "$(ls -A "$D" 2>/dev/null)" ]; then
  echo "出力先が空ではありません: $D" >&2
  exit 1
fi
mkdir -p "$D/out" "$STATE"
: > "$D/steps.log"
trap 'kill $(cat "$D/serve.pid" "$D/capture.pid" 2>/dev/null) 2>/dev/null' EXIT

step() { printf '%s %s\n' "$(python3 -c 'import time; print(int(time.time() * 1000))')" "$1" >> "$D/steps.log"; }
desired_stopped() {
  printf '{"sources":[]}' > "$STATE/capture-desired.json.tmp"
  mv "$STATE/capture-desired.json.tmp" "$STATE/capture-desired.json"
}
start_capture() {
  "$BIN" capture-daemon 2>> "$D/capture.err" &
  echo $! > "$D/capture.pid"
}
# serveのstdinをFIFOにつなぎ、書き手を開いたままにしてEOF（quit扱い）にならないようにする
start_serve() {
  "$BIN" serve --output "$D/out" --owner 山田 --source both < "$D/cmd" >> "$D/events.log" 2>> "$D/serve.err" &
  echo $! > "$D/serve.pid"
  exec 3> "$D/cmd"
}
send() { printf '%s\n' "$1" >&3; }
wait_for() {
  for _ in $(seq 1 60); do
    grep -q "$1" "$D/events.log" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

rm -f "$D/cmd"
mkfifo "$D/cmd"
desired_stopped
start_capture
sleep 2
start_serve
wait_for 'serve ready' || { step serve-not-ready; exit 1; }
step ready

send '{"cmd":"start"}'
sleep 3
step started
cp "$STATE/capture-desired.json" "$D/desired-recording.json"
cp "$STATE/capture-actual.json" "$D/actual-recording.json"

step say1
say -v Kyoko "一つ目の確認です。時刻が壁時計に合っているかを確かめます。"
sleep 1
say -v Otoya "はい、わかりました。"
sleep 8

send '{"cmd":"rotate"}'
sleep 3
step rotated
step say2
say -v Kyoko "区切った後の発話です。"
sleep 8

kill -9 "$(cat "$D/serve.pid")"
exec 3>&-
step serve-killed
sleep 5
start_serve
wait_for 'resumed' || step serve-not-resumed
step serve-restarted
step say3
say -v Kyoko "serveを起動し直した後の発話です。"
sleep 8

kill -9 "$(cat "$D/capture.pid")"
step capture-killed
sleep 8
cp "$STATE/capture-actual.json" "$D/actual-while-dead.json"
start_capture
sleep 4
step capture-restarted
step say4
say -v Kyoko "capture-daemonを起動し直した後の発話です。"
sleep 8

send '{"cmd":"stop"}'
sleep 3
step stopped
cp "$STATE/capture-desired.json" "$D/desired-stopped.json"
sleep 2
cp "$STATE/capture-actual.json" "$D/actual-stopped.json"
send '{"cmd":"quit"}'
exec 3>&-
sleep 2
kill -TERM "$(cat "$D/capture.pid")"
sleep 2
ls -a "$STATE" > "$D/state-dir.txt"

# 起動したprocessが終わったcapture-daemonは、自分で取り込みを止めて終える
bash -c '"$0" capture-daemon 2>> "$1" & echo $! > "$2"; sleep 2' "$BIN" "$D/capture.err" "$D/orphan.pid"
sleep 3
if kill -0 "$(cat "$D/orphan.pid")" 2>/dev/null; then
  echo alive > "$D/orphan.txt"
  kill -TERM "$(cat "$D/orphan.pid")"
else
  echo exited > "$D/orphan.txt"
fi
step done
```

`.claude/skills/daemon-realtest/scripts/cli-cycle-report.py`:

```python
#!/usr/bin/env python3
"""cli-cycle.shの結果を読み、段階1の確認項目ごとに合否を出す。

usage: cli-cycle-report.py <cli-cycle.shの出力先directory>
"""
import bisect
import glob
import json
import os
import sys

SAMPLE_RATE = 16_000
UNRESPONSIVE = "capture-daemonが応答していません"


def records(path):
    result = []
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return result


def anchors(meta_path):
    return sorted((r["sample"], r["ms"]) for r in records(meta_path) if r.get("t") == "anchor")


def wall_ms(points, sample):
    index = max(bisect.bisect_right([s for s, _ in points], sample) - 1, 0)
    anchor_sample, anchor_ms = points[index]
    return anchor_ms + (sample - anchor_sample) * 1000 / SAMPLE_RATE


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    directory = sys.argv[1]
    steps = {}
    with open(f"{directory}/steps.log", encoding="utf-8") as lines:
        for line in lines:
            ms, name = line.split(" ", 1)
            steps[name.strip()] = int(ms)
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok), detail))

    timed = sorted(glob.glob(f"{directory}/out/*.timed.jsonl"))
    check("開始と区切りで収録が2つできた", len(timed) == 2, ", ".join(os.path.basename(p) for p in timed))
    if len(timed) == 2:
        first, second = (records(p) for p in timed)
        prefix2 = os.path.basename(timed[1]).removesuffix(".timed.jsonl")
        segs1 = [r for r in first if r.get("t") == "seg"]
        segs2 = [r for r in second if r.get("t") == "seg"]

        for key, segs in (("say1", segs1), ("say2", segs2), ("say3", segs2), ("say4", segs2)):
            candidates = [s for s in segs if s["start"] >= steps[key] - 1000]
            seg = min(candidates, key=lambda s: s["start"]) if candidates else None
            delay = seg["start"] - steps[key] if seg else None
            check(
                f"{key}の発話が壁時計の時刻で記録された（話し始めから4秒以内）",
                seg is not None and -500 <= delay <= 4000,
                f"{delay}ms {seg['source']} {seg['text']}" if seg else "segが無い")

        check("収録中の発話に話者が付いていない", all("speaker" not in s for s in segs1 + segs2))

        before = [s for s in segs2 if s["received_at"] < steps["serve-killed"]]
        after = [s for s in segs2 if s["received_at"] > steps["serve-restarted"]]
        check(
            "serveの再起動後も同じ収録へseqを続けて書いた",
            before and after and min(s["seq"] for s in after) > max(s["seq"] for s in before),
            f"再起動の前{len(before)}件、後{len(after)}件")

        old_directory = json.load(open(f"{directory}/desired-recording.json"))["recording"]["directory"]
        new_directory = os.path.join(os.path.dirname(old_directory), prefix2)
        old_points = anchors(f"{old_directory}/mic.meta.jsonl")
        new_points = anchors(f"{new_directory}/mic.meta.jsonl")
        if old_points and new_points:
            old_end = wall_ms(old_points, os.path.getsize(f"{old_directory}/mic.pcm") // 4)
            gap = new_points[0][1] - old_end
            check("区切りの前後でmicの生音声の時刻が続いている（500ms以内）", abs(gap) <= 500, f"{gap:.0f}ms")
        else:
            check("区切りの前後でmicの生音声の時刻が続いている（500ms以内）", False, "anchorが無い")
        check(
            "capture-daemonの再起動の後、同じ収録へanchorを足して書き続けた",
            any(ms > steps["capture-killed"] for _, ms in new_points),
            f"anchor {len(new_points)}個")

    events = records(f"{directory}/events.log")
    statuses = [e for e in events if e.get("ev") == "status"]
    check(
        "収録中はsourceごとの取り込みの状態をstatusで伝えた",
        any(any(c.get("state") == "recording" for c in e.get("capture") or []) for e in statuses))
    check(
        "capture-daemonが止まった間は応答なしを伝えた",
        any(any(c.get("reason") == UNRESPONSIVE for c in e.get("capture") or []) for e in statuses))
    check("serveが収録を引き継いだ", any("resumed" in e.get("message", "") for e in events))

    desired = json.load(open(f"{directory}/desired-stopped.json"))
    check("停止で望む状態から収録が消えた", "recording" not in desired)
    actual = json.load(open(f"{directory}/actual-stopped.json"))
    check("停止でcapture-daemonが書くのをやめた", actual.get("prefix") is None and actual["sources"] == [])
    check("final.mdが2つ書かれた", len(glob.glob(f"{directory}/out/*.final.md")) == 2)
    with open(f"{directory}/state-dir.txt", encoding="utf-8") as listing:
        leftovers = [name for name in listing.read().split() if name.endswith(".tmp")]
    check("状態ディレクトリに一時ファイルが残っていない", not leftovers, " ".join(leftovers))
    with open(f"{directory}/orphan.txt", encoding="utf-8") as orphan:
        check("起動したprocessが終わったcapture-daemonは自分で終えた", orphan.read().strip() == "exited")

    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
```

```bash
chmod +x .claude/skills/daemon-realtest/scripts/cli-cycle.sh .claude/skills/daemon-realtest/scripts/cli-cycle-report.py
bash -n .claude/skills/daemon-realtest/scripts/cli-cycle.sh
python3 -m py_compile .claude/skills/daemon-realtest/scripts/cli-cycle-report.py
```

Expected: どちらもerrorを出さない

- [ ] **Step 9: CLIで一巡する（実機）**

前提はTask 6のStep 2と同じ（Notetake.appが止まっている、`make daemon`が終わっている）。userに「約2分、system音声で`say`の読み上げが流れます」と伝えてから、repoのrootで`run_in_background`で走らせる:

```bash
.claude/skills/daemon-realtest/scripts/cli-cycle.sh <scratchpad>/cli-cycle-1
```

終わったら（`steps.log`の最後の行が`done`）判定する:

```bash
python3 .claude/skills/daemon-realtest/scripts/cli-cycle-report.py <scratchpad>/cli-cycle-1
```

Expected: すべて`PASS`。`FAIL`があれば、`events.log`、`serve.err`、`capture.err`、生音声の`.meta.jsonl`を読んで原因を特定してから直す（`superpowers:systematic-debugging`）。端末のappにマイクの許可が無いとmicは無音になるが、anchorと時刻の確認には影響しない

- [ ] **Step 10: commit（controller）**

```bash
git add Sources/notetaked/Pipeline/ServeSession.swift Sources/notetaked/Commands/ServeCommand.swift Sources/NotetakeCore/Session/SessionStore.swift Tests/NotetakeCoreTests/SessionStoreTests.swift .claude/skills/daemon-realtest/scripts/cli-cycle.sh .claude/skills/daemon-realtest/scripts/cli-cycle-report.py
git commit -m "$(cat <<'MSG'
feat(serve): record through the desired state and live transcription

serve writes session.json and the desired state to start, rotate and
stop recordings, transcribes each source with LiveTranscription, and
reads capture-actual.json every second to forward capture state, input
resets and write errors. A recording still marked in the desired state
when serve starts is resumed from its timed.jsonl. Realtime diarization,
the speaker registry, checkpoints and the resume marker no longer take
part. cli-cycle.sh drives a full start, rotate, crash and stop cycle
from the command line and cli-cycle-report.py checks the result.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 12: 使わなくなったものを取り除く

Task 11で、収録中の話者分離、再開位置の記録、命令とeventのファイル、古い生音声の形式を使わなくなった。それらと、それらのためだけにあった`Reconciler`の話者の継承と停止時の二次解決を消す。二次解決が無くなるため、その効果を見る`fallback-diff.sh`も消す。FluidAudioは段階2の確定処理で使うため、`Package.swift`の依存に残す。

**Files:**
- Delete:
  - `Sources/NotetakeDiarization/Diarizer.swift`（targetごと）
  - `Sources/NotetakeCore/Speaker/Aligner.swift`、`ProfileNameAnnouncer.swift`、`SpeakerRegistry.swift`、`SpeakerTurn.swift`
  - `Sources/NotetakeCore/Capture/CaptureCheckpoint.swift`、`CaptureControlChannel.swift`、`RawAudioFrame.swift`、`RawAudioReader.swift`、`RawAudioWriter.swift`
  - `Sources/NotetakeCore/Control/CaptureCommand.swift`
  - `Sources/notetaked/Audio/AudioCapture.swift`、`Sources/notetaked/Audio/RawAudioReaderCapture.swift`
  - `Sources/notetaked/Pipeline/CaptureStream.swift`、`Sources/notetaked/SpeakerProfileStore.swift`
  - `Tests/NotetakeCoreTests/AlignerTests.swift`、`SpeakerRegistryTests.swift`、`ProfileNameAnnouncerTests.swift`、`CaptureCheckpointTests.swift`、`CaptureControlChannelTests.swift`、`CaptureCommandTests.swift`、`RawAudioFrameTests.swift`、`RawAudioWriterReaderTests.swift`
  - `Tests/notetakedTests/RawAudioReaderCaptureTests.swift`
  - `.claude/skills/recordings/scripts/fallback-diff.sh`
- Modify: `Package.swift`、`Sources/NotetakeCore/Capture/CaptureStatePaths.swift`、`Sources/NotetakeCore/Capture/CaptureSessionPaths.swift`、`Sources/NotetakeCore/Reconcile/Reconciler.swift`、`Sources/NotetakeCore/Session/SessionStore.swift`、`Sources/NotetakeCore/Model/Segment.swift`（comment）、`Sources/NotetakeCore/Transcribe/TranscriptRun.swift`（comment）、`Sources/NotetakeCore/Transcribe/Transcriber.swift`（comment）、`Sources/notetaked/Peer/ReceivedCursor.swift`（comment）、`Tests/NotetakeCoreTests/ReconcilerTests.swift`、`Tests/NotetakeCoreTests/SessionStoreTests.swift`、`Tests/NotetakeCoreTests/HeartbeatTests.swift`、`.claude/skills/recordings/SKILL.md`

**Interfaces:**
- Produces: なし（消すだけ）。`Reconciler.Config`から`speakerInheritanceGapMS`が、`Reconciler`から`resolveFallbackSpeakers()`が、`SessionStore`から`speakersURL`と`writeSpeakers(_:)`が無くなる

- [ ] **Step 1: 継承が無くなったことを表すテストに変える**

`Tests/NotetakeCoreTests/ReconcilerTests.swift`から、次の5件を消す: `speakerlessSegmentInheritsPriorSameDeviceSpeakerWithinGap`、`speakerlessSegmentFallsBackToOwnerWhenGapExceedsThreshold`、`resolveFallbackSpeakersInheritsFromFollowingUtteranceWhenPriorGapExceedsThreshold`、`resolveFallbackSpeakersKeepsOwnerLabelWhenPriorAndFollowingSpeakersConflict`、`resolveFallbackSpeakersKeepsOwnerLabelWhenNoNeighborOnSameDevice`。代わりに次を足す:

```swift
@Test func speakerlessSegmentShowsTheOwnerEvenAfterASpeakerOnTheSameDevice() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", owner: "山田", start: 0, end: 1000, text: "うん", global: "g2"))
    let out = r.apply(seg(device: "mac1", owner: "山田", start: 1500, end: 2500, text: "連絡きたの"))
    #expect(out[0].speakerID == nil)
    #expect(out[0].speaker == "山田")
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter speakerlessSegmentShowsTheOwner`
Expected: FAIL（継承によって`speakerID`が`g2`になる）

- [ ] **Step 3: Reconcilerから継承と二次解決を消す**

`Sources/NotetakeCore/Reconcile/Reconciler.swift`:
- `Config`から`speakerInheritanceGapMS`とそのcommentを消す
- `makeUtterance`の`speakerID: seg.speaker?.global ?? inheritedSpeakerID(for: seg, start: start),`を`speakerID: seg.speaker?.global,`にする
- `/// speakerが付かないsegについて、同じdeviceの直前のutteranceの話者を、`で始まる`inheritedSpeakerID`から、`nearestAfterSpeakerID`の終わりまで（`// MARK: - fallback speaker resolution (second pass)`、`resolveFallbackSpeakers`、`resolveFallbackSpeakerID`、`nearestBeforeSpeakerID`を含む）を消す
- `merge`の中を次のようにする:

```swift
        if merged.speakerID == nil {
            merged.speakerID = seg.speaker?.global
        }
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter 'speakerless|losingSegment|speakerName|foldEquals|restoreFolds'`
Expected: PASS

- [ ] **Step 5: ファイルを消す**

実装者は`rm`で消す（gitを変更しない）。削除はStep 11のcontrollerの`git add -A`が反映する:

```bash
rm -r Sources/NotetakeDiarization
rm Sources/NotetakeCore/Speaker/Aligner.swift Sources/NotetakeCore/Speaker/ProfileNameAnnouncer.swift Sources/NotetakeCore/Speaker/SpeakerRegistry.swift Sources/NotetakeCore/Speaker/SpeakerTurn.swift
rm Sources/NotetakeCore/Capture/CaptureCheckpoint.swift Sources/NotetakeCore/Capture/CaptureControlChannel.swift Sources/NotetakeCore/Capture/RawAudioFrame.swift Sources/NotetakeCore/Capture/RawAudioReader.swift Sources/NotetakeCore/Capture/RawAudioWriter.swift Sources/NotetakeCore/Control/CaptureCommand.swift
rm Sources/notetaked/Audio/AudioCapture.swift Sources/notetaked/Audio/RawAudioReaderCapture.swift Sources/notetaked/Pipeline/CaptureStream.swift Sources/notetaked/SpeakerProfileStore.swift
rm Tests/NotetakeCoreTests/AlignerTests.swift Tests/NotetakeCoreTests/SpeakerRegistryTests.swift Tests/NotetakeCoreTests/ProfileNameAnnouncerTests.swift Tests/NotetakeCoreTests/CaptureCheckpointTests.swift Tests/NotetakeCoreTests/CaptureControlChannelTests.swift Tests/NotetakeCoreTests/CaptureCommandTests.swift Tests/NotetakeCoreTests/RawAudioFrameTests.swift Tests/NotetakeCoreTests/RawAudioWriterReaderTests.swift Tests/notetakedTests/RawAudioReaderCaptureTests.swift
rm .claude/skills/recordings/scripts/fallback-diff.sh
```

- [ ] **Step 6: Package.swiftから話者分離のtargetを外す**

`Package.swift`を次の内容にする:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "notetaked",
    platforms: [.macOS("26.0"), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "NotetakeCore", targets: ["NotetakeCore"]),
        .executable(name: "notetaked", targets: ["notetaked"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
    ],
    targets: [
        .target(name: "NotetakeCore"),
        .executableTarget(
            name: "notetaked",
            dependencies: [
                "NotetakeCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "NotetakeCoreTests", dependencies: ["NotetakeCore"]),
        .testTarget(name: "notetakedTests", dependencies: ["notetaked"]),
    ]
)
```

- [ ] **Step 7: 古いpathと話者の書き出しを消す**

`Sources/NotetakeCore/Capture/CaptureStatePaths.swift`を次の内容にする:

```swift
import Foundation

public enum CaptureStatePaths {
    public static func stateDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notetake").appendingPathComponent("state")
    }

    public static var processHeartbeatURL: URL { stateDirectory().appendingPathComponent("process.heartbeat") }
    public static var captureDesiredURL: URL { stateDirectory().appendingPathComponent("capture-desired.json") }
    public static var captureActualURL: URL { stateDirectory().appendingPathComponent("capture-actual.json") }
}
```

`Sources/NotetakeCore/Capture/CaptureSessionPaths.swift`から`rawFileURL(sessionDirectory:source:)`と`checkpointFileURL(sessionDirectory:source:)`を消す。

`Sources/NotetakeCore/Session/SessionStore.swift`から、`speakersURL`の宣言、`init(directory:prefix:)`の`self.speakersURL = ...`の行、`writeSpeakers(_:)`（その上のcommentを含む）を消す。

`Tests/NotetakeCoreTests/SessionStoreTests.swift`の`urlsUsePrefix`から`speakersURL`の`#expect`の行を消し、`writeSpeakersWritesSortedPrettyJSON`と`writeSpeakersOverwrites`を消す。

`Tests/NotetakeCoreTests/HeartbeatTests.swift`の`statePathsAreDistinct`の配列を次にする:

```swift
    let paths = [
        CaptureStatePaths.processHeartbeatURL,
        CaptureStatePaths.captureDesiredURL,
        CaptureStatePaths.captureActualURL,
    ]
```

- [ ] **Step 8: 消した型に触れていたcommentを直す**

`Sources/NotetakeCore/Model/Segment.swift`の`SpeakerTag`:

```swift
    public var local: String?        // 話者分離がsourceの中で付けたid
    public var global: String?       // 話者のid。表示名はspeaker_nameの記録が付ける
    public var embedding: [Float]?   // 話者の声の特徴（256次元）
```

`Sources/NotetakeCore/Transcribe/TranscriptRun.swift`の`/// Aligner等の純粋ロジックがこの型を利用できる。`を`/// 話者の割り当てなどの純粋な処理がこの型を使える。`にする。

`Sources/notetaked/Peer/ReceivedCursor.swift`の`（`DeviceIdentity` / `SpeakerProfileStore`と同じディレクトリ規則）`を`（`DeviceIdentity`と同じディレクトリ規則）`にする。

`.claude/skills/recordings/SKILL.md`から、`- 話者の大域profile:`で始まる行と、`- issue #8検証`で始まる行を消す。

`Sources/NotetakeCore/Transcribe/Transcriber.swift`の`finish()`のcommentの最後の2行を次にする（iPhoneのRecorderとWatchRelayも同じ`finish()`を使う）:

```swift
    /// start()が返したAsyncStreamのcontinuationも直接finishして、piecesを読む側が待ち続けないようにする。
```

- [ ] **Step 9: 消した型への参照が残っていないことを確かめる**

Run:

```bash
grep -rn -E "SpeakerRegistry|SpeakerProfile|Aligner|AlignedPiece|SpeakerTurn|Diarizer|NotetakeDiarization|CaptureCheckpoint|RawAudio(Frame|Reader|Writer|ReaderCapture)|CaptureControlChannel|CaptureCommand|CaptureEvent|CaptureStream|\bAudioCapture\b|currentSessionMarker|captureCommandURL|captureEventURL|resolveFallbackSpeakers|inheritedSpeakerID|ProfileNameAnnouncer|writeSpeakers|speakersURL|rawFileURL|checkpointFileURL|fallback-diff" Sources Tests Apps/Notetake Apps/NotetakeMobile Apps/NotetakeWatch Package.swift .claude/skills/recordings
```

Expected: 出力なし

README、AGENTS.md、skillsにも消した型や話者の書き出しへの参照が無いかを見る（Task 13と15で直すものだけが残る）:

```bash
grep -rn -E "SpeakerRegistry|SpeakerProfile|Aligner|SpeakerTurn|Diarizer|NotetakeDiarization|CaptureCheckpoint|RawAudio(Frame|Reader|Writer|ReaderCapture)|CaptureControlChannel|CaptureCommand|CaptureEvent|CaptureStream|\bAudioCapture\b|currentSessionMarker|resolveFallbackSpeakers|inheritedSpeakerID|ProfileNameAnnouncer|fallback-diff|diarizer|--diarize|--no-diarize|speakers\.json|\.speakers" README.md AGENTS.md .claude/skills
```

Expected: 次の行だけが出る。どれもTask 13か15で直す。これ以外が出たら、そのファイルの直しを該当のtaskの手順に足す
- `README.md`の12・13・18・52行目（Task 15 Step 1）
- `.claude/skills/recordings/SKILL.md`の3行目のdescription（Task 15 Step 3）
- `.claude/skills/mac-app/SKILL.md`の11行目と`.claude/skills/mac-app/scripts/launch.sh`の22・23・27行目（Task 13 Step 8）
- `.claude/skills/daemon-realtest/SKILL.md`の38・39・64行目（Task 15 Step 2で書き直す）

`HANDOFF.md`は過去の記録に消した型の名前が残るため、grepの対象にしない。現在の状態を書いた箇所の直しはTask 15 Step 4にある

- [ ] **Step 10: 検証ゲート**

Run: `make verify`
Expected: 最終行`verify: OK`。テストの数はTask 11の時より減る（消したテストの分）

- [ ] **Step 11: commit（controller）**

```bash
git add -A Package.swift Sources Tests .claude/skills/recordings
git commit -m "$(cat <<'MSG'
refactor: remove realtime diarization and the old capture channel

Delete the online diarizer target, Aligner, SpeakerRegistry and its
global profiles, ProfileNameAnnouncer, the speaker inheritance and
second pass in Reconciler, CaptureStream, RawAudioReaderCapture, the
framed raw audio format, checkpoints, and the command and event files.
FluidAudio stays as a dependency for the offline diarizer of the next
stage.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 13: Notetake.appのメニューに取り込みの状態を出す

収録中、メニューにsourceごとの取り込みの状態（取り込み中、再開待ちと理由、停止）を出す。serveは取り込みの状態が変わるたびに`status` eventを送るようになったため、appが`status`のたびに`lastError`を消すと、直前の`error`がすぐ消える。`lastError`を消すのは新しい収録が始まった時だけにし、serveの`error`には受け取った時刻を付ける（エラーが次の収録まで残るため、いつのものか分かるようにする）。

ハングと判定したserveは、quitを送らずにSIGKILLで止める。quitを受けたserveは収録を止めて望む状態を空にするため、遅れていただけのserveを止めると収録が終わってしまう。SIGKILLなら望む状態が残り、起動し直したserveが同じ収録を引き継ぐ。Macのスリープから戻った直後は、serveとcapture-daemonが心拍を書き直す前で古く見えるため、30秒はハングの判定をしない。

serveは話者分離のmodelを準備しなくなったため、起動の確認（`launch.sh`）は`diarizer ready`ではなく`serve ready`を待つ。

**Files:**
- Create: `Sources/NotetakeCore/Render/CaptureStatusLabel.swift`
- Modify: `Apps/Notetake/AppModel.swift`、`Apps/Notetake/DaemonClient.swift`、`Apps/Notetake/MenuContent.swift`、`.claude/skills/mac-app/scripts/launch.sh`、`.claude/skills/mac-app/SKILL.md`
- Test: `Tests/NotetakeCoreTests/CaptureStatusLabelTests.swift`

**Interfaces:**
- Consumes: `CaptureStatus`、`StatusEvent.capture`（Task 10）
- Produces: `CaptureStatusLabel.text(for: CaptureStatus) -> String`。`AppModel.captureStatuses: [CaptureStatus]`。`DaemonClient.forceKill() async`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/CaptureStatusLabelTests.swift`:

```swift
import Foundation
import Testing
@testable import NotetakeCore

@Test func captureStatusLabelNamesTheSourceAndState() {
    #expect(CaptureStatusLabel.text(for: CaptureStatus(source: .mic, state: .recording)) == "マイク: 取り込み中")
    #expect(
        CaptureStatusLabel.text(
            for: CaptureStatus(source: .system, state: .retrying, reason: "The stream was stopped by the system"))
            == "system音声: 再開待ち（The stream was stopped by the system）")
    #expect(CaptureStatusLabel.text(for: CaptureStatus(source: .system, state: .retrying)) == "system音声: 再開待ち")
    #expect(CaptureStatusLabel.text(for: CaptureStatus(source: .mic, state: .off)) == "マイク: 停止")
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `swift test --filter captureStatusLabel`
Expected: buildが`cannot find 'CaptureStatusLabel' in scope`で失敗する

- [ ] **Step 3: 文を作る関数を実装する**

`Sources/NotetakeCore/Render/CaptureStatusLabel.swift`:

```swift
/// メニューに出す、sourceごとの取り込みの状態の文
public enum CaptureStatusLabel {
    public static func text(for status: CaptureStatus) -> String {
        let name =
            switch status.source {
            case .mic: "マイク"
            case .system: "system音声"
            case .watch: "Watch"
            }
        switch status.state {
        case .recording:
            return "\(name): 取り込み中"
        case .retrying:
            return "\(name): 再開待ち" + (status.reason.map { "（\($0)）" } ?? "")
        case .off:
            return "\(name): 停止"
        }
    }
}
```

- [ ] **Step 4: 通ることを確かめる**

Run: `swift test --filter captureStatusLabel`
Expected: PASS

- [ ] **Step 5: AppModelに取り込みの状態を持たせる**

`Apps/Notetake/AppModel.swift`の`var sources: [Source] = []`の次に足す:

```swift
    /// 収録中のsourceごとの取り込みの状態（daemonの`status.capture`）。停止中は空
    var captureStatuses: [CaptureStatus] = []
```

`handle(_:)`の`.status`で、`lastError`を消す条件を変える。前:

```swift
            if status.recording {
                lastError = nil
            } else {
                volatile = [:]
            }
```

後:

```swift
            if isNewRecording {
                lastError = nil
            }
            if !status.recording {
                volatile = [:]
            }
```

同じ`.status`の`inputSpatial = status.inputSpatial`の次に足す:

```swift
            captureStatuses = status.capture ?? []
```

`handleExit(_:_:)`の`prefix = nil`の次に足す:

```swift
        captureStatuses = []
```

`handle(_:)`の`.error`で、受け取った時刻を付ける。前:

```swift
        case .error(let message):
            lastError = message
```

後:

```swift
        case .error(let message):
            lastError = "\(Date().formatted(date: .omitted, time: .shortened)) \(message)"
```

- [ ] **Step 6: ハングの時はquitを送らずに止め、スリープ復帰の直後は判定しない**

`Apps/Notetake/DaemonClient.swift`の`func terminate(wasRecording: Bool = false) async {`の前に足す:

```swift
    /// 応答しないserveをSIGKILLで止める。quitを送ると、serveは収録を止めて望む状態を空にするため送らない。
    /// 望む状態が残るので、起動し直したserveが同じ収録を引き継ぐ
    func forceKill() async {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

```

`Apps/Notetake/AppModel.swift`の`private static let restartDelay: TimeInterval = 1`の次に足す:

```swift
    private static let wakeGrace: TimeInterval = 30
```

`private var heartbeatMonitorTask: Task<Void, Never>?`の次に足す:

```swift
    /// Macがスリープから戻った時刻。戻った直後は、serveとcapture-daemonが心拍を書き直す前で古く見えるため、
    /// `wakeGrace`の間はハングの判定をしない
    private var lastWakeAt: Date?
    private var wakeObserver: (any NSObjectProtocol)?
```

`init()`の心拍の見張り。前:

```swift
        heartbeatMonitorTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !self.isShuttingDown else { continue }
```

後:

```swift
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastWakeAt = Date()
            }
        }
        heartbeatMonitorTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !self.isShuttingDown else { continue }
                if let lastWakeAt = self.lastWakeAt, Date().timeIntervalSince(lastWakeAt) < Self.wakeGrace {
                    continue
                }
```

同じ見張りの、serveのハングを見つけた時の処理。前:

```swift
                    self.lastError = "processがハングしたため再起動します"
                    await self.client?.terminate(wasRecording: self.isRecording)
                    // terminate()が実際に殺せたとしても、handleExit()のprocess.terminationHandler経由の
```

後:

```swift
                    self.lastError = "serveが応答しないため、止めて起動し直します"
                    await self.client?.forceKill()
                    // forceKill()で止めた後も、handleExit()のprocess.terminationHandler経由の
```

- [ ] **Step 7: メニューに出す**

`Apps/Notetake/MenuContent.swift`の`import SwiftUI`の前に`import NotetakeCore`を足し、`Text(statusText)`の次に足す:

```swift
        if appModel.isRecording {
            ForEach(appModel.captureStatuses, id: \.source) { status in
                Text(CaptureStatusLabel.text(for: status))
                    .foregroundStyle(.secondary)
            }
        }
```

- [ ] **Step 8: 起動の確認が`serve ready`を待つようにする**

```bash
sed -i '' 's/diarizer ready/serve ready/g' .claude/skills/mac-app/scripts/launch.sh
grep -n "ready" .claude/skills/mac-app/scripts/launch.sh
```

Expected: `serve ready`が3箇所あり、`diarizer`が無い

`.claude/skills/mac-app/SKILL.md`を6箇所直す。

frontmatterの`description`。前:

```markdown
description: Notetake.app（メニューバーapp + daemon）を起動し、メニュー項目・設定Window・話者命名をSystem Eventsで自動操作し、画面を撮って確認する。実機 / UI検証で人の代わりに操作する時に使う
```

後:

```markdown
description: Notetake.app（メニューバーapp + daemon）を起動し、メニュー項目・設定WindowをSystem Eventsで自動操作し、画面を撮って確認する。実機 / UI検証で人の代わりに操作する時に使う
```

`## 音声を入れる`の段落。前:

```markdown
`say -v Kyoko "…"`（system音声として取り込まれる。マイク経由の認識は不安定）。Otoyaで2話者目
```

後:

```markdown
`say -v Kyoko "…"`（system音声として取り込まれる。マイク経由の認識は不安定）。声を変えるなら`-v Otoya`。収録中の発話に話者は付かない
```

残りの4箇所:

`## 起動 / 停止`の1行目。前:

```markdown
- 起動（stderrを`/tmp/notetake-app.log`へ）: `scripts/launch.sh [logpath]` — 動いていれば「終了」してから起動し、`diarizer ready`まで待つ
```

後:

```markdown
- 起動（stderrを`/tmp/notetake-app.log`へ）: `scripts/launch.sh [logpath]` — 動いていれば「終了」してから起動し、`serve ready`まで待つ
```

`## メニューバーの操作`の`- 項目一覧（状態行・「次の区切り」・「接続: …」・`rotated`ログを含む）: `scripts/ntmenu.sh --list``の次に足す:

```markdown
- 収録中は、項目一覧にsourceごとの取り込みの状態（`マイク: 取り込み中`、`system音声: 再開待ち（理由）`など）が出る
```

`## ライブパネルの話者命名`の見出しと、その下の段落を消す（収録中の発話には話者が付かず、命名は段階2で「収録の話者」windowへ移る）。

`## 入力機器`の段落。前:

```markdown
`scripts/audioin.sh`（一覧、*が既定）/ `scripts/audioin.sh AirPods`（部分一致で既定入力を切替）。AirPodsを外すとmacOSが内蔵マイクへ戻す。daemonは開始 / 区切り時点の入力名をsegに書くので、切替後は「収録を区切る」
```

後:

```markdown
`scripts/audioin.sh`（一覧、*が既定）/ `scripts/audioin.sh AirPods`（部分一致で既定入力を切替）。AirPodsを外すとmacOSが内蔵マイクへ戻す。入力機器が変わると、capture-daemonが`mic.meta.jsonl`へdevice行を足し、以後の発話の`input`がその機器になる（区切らなくてよい）
```

- [ ] **Step 9: 検証ゲート**

Run: `make verify`（`make app`でappもbuildする）
Expected: 最終行`verify: OK`

- [ ] **Step 10: commit（controller）**

```bash
git add Sources/NotetakeCore/Render/CaptureStatusLabel.swift Tests/NotetakeCoreTests/CaptureStatusLabelTests.swift Apps/Notetake/AppModel.swift Apps/Notetake/DaemonClient.swift Apps/Notetake/MenuContent.swift .claude/skills/mac-app/scripts/launch.sh .claude/skills/mac-app/SKILL.md
git commit -m "$(cat <<'MSG'
feat(app): show capture state per source in the menu

The menu lists each source's capture state while recording, with the
reason while it waits to resume. Errors now clear only when a new
recording starts, since status events arrive whenever capture state
changes, and carry the time they arrived. A hung serve is killed with
SIGKILL instead of being sent quit, so the desired state survives and
the restarted serve resumes the recording; hang checks pause for 30
seconds after the Mac wakes. launch.sh waits for "serve ready" now that
serve no longer prepares diarizer models.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

### Task 14: 段階1を実機で確かめる

段階1のすべてのtaskを入れた状態で、CLIとappの両方で確かめる。結果（合否、数値、気づき）はSDDのledgerに書き、Task 15でHANDOFFへ移す。

**Files:** なし（確認だけ。確かめて不具合が見つかったら、`superpowers:systematic-debugging`で原因を特定し、直してから該当のtaskの確認をやり直す）

- [ ] **Step 1: 前提を揃える**

- `make verify`が通っている（`make daemon`も済む）
- Notetake.appが動いているかを`pgrep -x Notetake`で確かめ、動いていたかをledgerに書く（Step 6で起動し直すかを決める）。動いていたら、収録中かを確かめる（`~/Library/Application Support/Notetake/state/current-session.json`がある、または`.claude/skills/mac-app/scripts/ntmenu.sh --list`の状態行が収録中）。収録中なら、userに「収録を止めてよいか」を尋ね、了承を得るまで止めない。止めてよければ`.claude/skills/mac-app/scripts/ntmenu.sh "終了"`で止める

- [ ] **Step 2: CLIで一巡する**

userに「約2分、system音声で`say`の読み上げが流れます」と伝えてから、`run_in_background`で走らせる:

```bash
.claude/skills/daemon-realtest/scripts/cli-cycle.sh <scratchpad>/cli-cycle-2
```

終わったら:

```bash
python3 .claude/skills/daemon-realtest/scripts/cli-cycle-report.py <scratchpad>/cli-cycle-2
```

Expected: すべて`PASS`

- [ ] **Step 3: appで確かめる**

`make install-app`は`/Applications/Notetake.app`を段階1の版に置き換える。段階2を入れるまで、この版の収録には話者が付かない（Step 6でuserに伝える）。

```bash
make install-app
```

Expected: `launch.sh`が`serve ready`を見つけて`launched; log=/tmp/notetake-app.log`を出す

次のscriptを`<scratchpad>/app-check/check.sh`に置き、`run_in_background`で走らせる（userに「appで約1分半収録し、`say`が流れます。途中でserveを止め、appが起動し直すのを確かめます」と伝えてから）。serveを`kill -STOP`で止めたままにし、appがハングと見なしてSIGKILLで止め、起動し直したserveが同じ収録を引き継ぐことも確かめる:

```bash
#!/bin/bash
set -uo pipefail
D="$1"
M=.claude/skills/mac-app/scripts
STATE="$HOME/Library/Application Support/Notetake/state"
mkdir -p "$D"
"$M/ntmenu.sh" "収録開始"
sleep 5
"$M/ntmenu.sh" --list > "$D/menu-recording.txt"
cp "$STATE/capture-desired.json" "$D/desired-start.json"
say -v Kyoko "アプリからの確認です。メニューに取り込みの状態が出ています。"
sleep 8
pgrep -f 'notetaked serve' > "$D/serve-before.pid"
kill -STOP "$(head -n 1 "$D/serve-before.pid")"
sleep 40
pgrep -f 'notetaked serve' > "$D/serve-after.pid"
cp "$STATE/capture-desired.json" "$D/desired-after-hang.json"
say -v Kyoko "引き継いだ後の確認です。"
sleep 8
"$M/ntmenu.sh" "収録停止"
sleep 3
"$M/ntmenu.sh" --list > "$D/menu-stopped.txt"
echo done > "$D/finished"
```

Run（`run_in_background`）: `bash <scratchpad>/app-check/check.sh <scratchpad>/app-check`

終わったら:

```bash
cat <scratchpad>/app-check/menu-recording.txt
cat <scratchpad>/app-check/serve-before.pid <scratchpad>/app-check/serve-after.pid
cat <scratchpad>/app-check/desired-start.json <scratchpad>/app-check/desired-after-hang.json
.claude/skills/recordings/scripts/inspect.sh latest "$(defaults read io.github.bash0c7.notetake outputDirectory)"
grep -E 'notetaked (error|log)' /tmp/notetake-app.log | tail -n 20
```

Expected:
- `menu-recording.txt`に`マイク: 取り込み中`と`system音声: 取り込み中`がある
- `serve-after.pid`のpidが`serve-before.pid`と違う。2つの望む状態の`recording.prefix`が同じ。appのlogに`notetaked log: resumed <prefix>`がある
- その収録の`final.md`に`（system）`の行があり、話者は`リモート`。止める前と引き継いだ後の両方の発話がある
- appのlogに`notetaked error`が無い

- [ ] **Step 4: Task 6を後へ回した時だけ、appで消灯の確認をする**

Task 6で端末のappの許可が得られず確認を後へ回した場合だけ行う。userに一声かけてから、appで収録を始め、`say`の繰り返しと`pmset displaysleepnow`、90秒後の`caffeinate -u -t 2`を行い、収録を止めた後に、appの生音声ディレクトリ（`capture-desired.json`に書かれていた`directory`）へ`pcm-coverage.py`をかける。判定はTask 6のStep 5と同じ。判定Bなら、Task 7を行ってからTask 15へ進む

- [ ] **Step 5: 固定した入力機器が外れた時を確かめる（AirPodsがある時だけ）**

userにAirPodsを接続してもらえる時だけ行う。`.claude/skills/mac-app/scripts/audioin.sh`でAirPodsのUIDを調べ、ライブパネルの「入力デバイス」でAirPodsを選んでappで収録を始め、`blueutil --disconnect <AirPodsのMAC>`で外す（`blueutil`が無ければuserに外してもらう）。収録中に`capture-desired.json`の`recording.prefix`を控える（Step 6で消すため）。Expected: `mic.meta.jsonl`に既定の入力の`device`行が足され、`capture-actual.json`のmicが`"fell_back_from_pinned":true`になり、appの入力デバイスの選択が「既定」に戻る。AirPodsが無ければ「未確認」とledgerに書く

- [ ] **Step 6: 後片付け**

- appで収録が止まっていることを確かめ、`.claude/skills/mac-app/scripts/ntmenu.sh "終了"`で止める。以下の掃除は、appとcapture-daemonとserveが止まってから行う
- Step 3とStep 5でuserの保存先に作った収録を消す。prefixは、Step 3は`desired-start.json`の`recording.prefix`、Step 5は確かめた時に`capture-desired.json`から控えたもの。prefixを変数に入れ、空でないことと、そのprefixのファイルだけが対象であることを`ls`で確かめてから、ファイル名を指定して消す。`OUT`か`PREFIX`が空なら、消さずにここで止める:

```bash
OUT="$(defaults read io.github.bash0c7.notetake outputDirectory)"
PREFIX="<prefix>"
test -n "$OUT" && test -n "$PREFIX" || echo "OUTかPREFIXが空です。消さずに止めます"
ls "$OUT" | grep -F "$PREFIX"
ls -l "$OUT/$PREFIX.live.txt" "$OUT/$PREFIX.timed.jsonl" "$OUT/$PREFIX.final.md"
```

Expected: 1つ目の`ls`に`$PREFIX.live.txt`、`$PREFIX.timed.jsonl`、`$PREFIX.final.md`のほかが出ない。確かめたら消す。Step 5の収録があれば、`PREFIX`を入れ替えて繰り返す:

```bash
rm "$OUT/$PREFIX.live.txt" "$OUT/$PREFIX.timed.jsonl" "$OUT/$PREFIX.final.md"
```

- mainが状態ディレクトリに残した一時ファイル（`*.tmp-*`。`capture.heartbeat.tmp-*`と`process.heartbeat.tmp-*`で約600個）と、段階1で使わなくなったファイルを消す（段階1の版では作られない。mainの版へ戻すと、mainは要るものを作り直す）。先に`ls`で件数と名前を確かめてから消す:

```bash
STATE="$HOME/Library/Application Support/Notetake/state"
find "$STATE" -maxdepth 1 -name '*.tmp-*' -print | wc -l
find "$STATE" -maxdepth 1 -name '*.tmp-*' -print | head -n 3
ls -l "$STATE/capture.heartbeat" "$STATE/capture-command.json" "$STATE/capture-event.json" "$STATE/current-session.json"
```

`*.tmp-*`が状態ディレクトリ直下の一時ファイルだけで、4つのファイル（`current-session.json`は収録中でなければ無い）が使わなくなったものであることを確かめたら消す:

```bash
find "$STATE" -maxdepth 1 -name '*.tmp-*' -delete
rm -f "$STATE/capture.heartbeat" "$STATE/capture-command.json" "$STATE/capture-event.json" "$STATE/current-session.json"
ls -A "$STATE"
```

Expected: `capture-desired.json`、`capture-actual.json`、`process.heartbeat`、`capture-daemon.lock`のほかに無い
- 確認で作った生音声（`$TMPDIR/notetake-capture/`の`display-check-*`、`display-guard-*`と、`cli-cycle`とappの確認で作ったprefix）はOSの掃除に任せる
- userへ、`/Applications/Notetake.app`が段階1の版（段階2まで話者が付かない）になったことを伝え、普段の収録のためにmainの版へ戻すかを尋ねる。戻す場合は、mainのworktreeで`make install-app`を行う
- Step 1でNotetake.appが動いていた場合は、userが決めた版で起動し直す（段階1の版のままなら`open -a /Applications/Notetake.app`。mainの版へ戻すなら`make install-app`が起動する）。Step 1で止まっていた場合は、`make install-app`が起動したappを`.claude/skills/mac-app/scripts/ntmenu.sh "終了"`で止める

### Task 15: README、HANDOFF、検証用skillを段階1に合わせる

**Files:**
- Modify: `README.md`、`HANDOFF.md`、`AGENTS.md`、`.claude/skills/recordings/SKILL.md`
- Replace: `.claude/skills/daemon-realtest/SKILL.md`

- [ ] **Step 1: READMEを直す**

`README.md`の`## 構成`の表で、`notetaked`から`Notetake.app`までの4行を置き換える。前:

```markdown
| `notetaked` | `Sources/notetaked` | daemon（CLI）。`serve`で収録・話者分離・iPhone / Watchからの受信・`final.md`生成、`polish`で対話整形、`render` / `transcribe` / `capture` |
| `NotetakeCore` | `Sources/NotetakeCore` | 共有ロジック。Segment / Reconciler / SpeakerRegistry / LocationLabel / DirectionEstimator / PeerMessage など |
| `NotetakeDiarization` | `Sources/NotetakeDiarization` | FluidAudioによる話者分離 |
| Notetake.app | `Apps/Notetake` | メニューバーapp。daemonを子processとして起動・監視・再起動・終了し、ライブパネル（本文・話者命名・区切る・整形）と設定Windowを持つ |
```

後:

```markdown
| `notetaked` | `Sources/notetaked` | daemon（CLI）。`capture-daemon`でマイクとsystem音声を生音声として書き、`serve`で収録の開始・停止・区切り、ライブの文字起こし、iPhone / Watchからの受信、`final.md`の生成を行う。`polish`で対話整形、`render` / `transcribe` |
| `NotetakeCore` | `Sources/NotetakeCore` | 共有ロジック。生音声の形式と時刻の基準点 / Segment / Reconciler / LocationLabel / DirectionEstimator / PeerMessageなど |
| Notetake.app | `Apps/Notetake` | メニューバーapp。capture-daemonとserveを子processとして起動・監視・再起動・終了し、メニューにsourceごとの取り込みの状態を出す。ライブパネル（本文・区切る・整形）と設定Windowを持つ |
```

出力の段落。前:

```markdown
出力（設定「保存先」、既定`~/Downloads`）: `<prefix>.live.txt` / `.timed.jsonl`（全record）/ `.final.md`（`HH:mm:ss **話者**（場所）: 本文`）/ `.speakers.json` / `.polished.md`、`orphans.jsonl`。大域の話者profileは`~/Library/Application Support/Notetake/speakers.json`。
```

後:

```markdown
出力（設定「保存先」、既定`~/Downloads`）: `<prefix>.live.txt` / `.timed.jsonl`（全record）/ `.final.md`（`HH:mm:ss **話者**（場所）: 本文`）/ `.polished.md`、`orphans.jsonl`。収録中の発話には話者を付けず、micは自分の名前、systemは「リモート」と表示する。生音声は`$TMPDIR/notetake-capture/<prefix>/`（`<source>.pcm`は16kHz monoのFloat32、`<source>.meta.jsonl`は時刻の基準点と入力機器、`session.json`）に置き、削除はOSに任せる。
```

`## 必要なもの`の2行目。前:

```markdown
- 初回はネット: `swift package --disable-keychain --disable-netrc resolve`（FluidAudioのbinaryTarget）、FluidAudioのモデル（Hugging Face、`serve`初回）、ja-JP音声モデル
```

後:

```markdown
- 初回はネット: `swift package --disable-keychain --disable-netrc resolve`（FluidAudioのbinaryTarget）、ja-JP音声モデル
```

`## 使い方`の2。前:

```markdown
2. メニュー / ライブパネルの「収録開始」「収録停止」「区切る」（prefixを切り替える）「整形」（直前の収録を`polish`）。パネルの話者名クリックで命名（次回起動以降も同じ声に同じ名前が付く）
```

後（Task 7を行った時は、行の最後に`system音声が鳴っている間（最後の音から5分）は、ディスプレイの消灯を防ぐ。`を足す）:

```markdown
2. メニュー / ライブパネルの「収録開始」「収録停止」「区切る」（prefixを切り替える）「整形」（直前の収録を`polish`）。メニューにsourceごとの取り込みの状態（取り込み中 / 再開待ち / 停止）が出る。ディスプレイの消灯などでsystem音声が止まると、capture-daemonが5秒ごとに作り直す。
```

CLI単体の段落。前:

```markdown
CLI単体: `.build/release/notetaked serve --output <dir> --owner <名前> --source both [--pair-code 123456] [--no-diarize]`（stdinに`{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdoutに`status` / `utterance` / `volatile` / `peer` / `log` / `error`イベント）。
```

後:

```markdown
CLI単体: `.build/release/notetaked capture-daemon`を起動しておき、`.build/release/notetaked serve --output <dir> --owner <名前> --source both [--pair-code 123456]`（stdinに`{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdoutに`status` / `utterance` / `volatile` / `peer` / `log` / `error` / `input_reset`イベント）。serveは`capture-desired.json`でcapture-daemonへ取り込みを指示する。
```

`## ドキュメント`のskillの行。前:

```markdown
- `.claude/skills/`: `verify`（検証ゲート）/ `mac-app`（appの起動・メニュー・設定の自動操作）/ `device`（iPhone / Watchのインストール・起動・crash log）/ `recordings`（収録結果の確認）
```

後:

```markdown
- `.claude/skills/`: `verify`（検証ゲート）/ `mac-app`（appの起動・メニュー・設定の自動操作）/ `device`（iPhone / Watchのインストール・起動・crash log）/ `recordings`（収録結果と生音声の確認）/ `daemon-realtest`（capture-daemonとserveのCLIでの実機検証）
```

1行目の説明（`README.md`の5行目）の最後の括弧。段階1ではFluidAudioを使わない（段階2の確定処理で使う）。前:

```markdown
Macのメニューバーappとdaemonで会議音声（マイク + システム音声）をリアルタイムに文字起こしし、iPhone / Apple Watchで拾った音声も同じ収録に統合してMarkdownの議事録にする。全てローカルで動く（Speech / FluidAudio / Foundation Models）。
```

後:

```markdown
Macのメニューバーappとdaemonで会議音声（マイク + システム音声）をリアルタイムに文字起こしし、iPhone / Apple Watchで拾った音声も同じ収録に統合してMarkdownの議事録にする。全てローカルで動く（Speech / Foundation Models）。
```

`## ドキュメント`の2行目（`README.md`の61行目）。2026-09-12のspecは収録中の話者分離を前提にしており、現行の設計は2026-10-03のspecにある。前:

```markdown
- `docs/superpowers/specs/2026-09-12-notetake-design.md`: 全体設計（binding）。他のspec / planは`docs/superpowers/`
```

後:

```markdown
- `docs/superpowers/specs/2026-09-12-notetake-design.md`: 最初の全体設計（収録中の話者分離を前提にしている）。現行の設計は`docs/superpowers/specs/2026-10-03-batch-finalize-redesign-design.md`。他のspec / planは`docs/superpowers/`
```

- [ ] **Step 2: daemon-realtestのskillを書き直す**

`.claude/skills/daemon-realtest/SKILL.md`を次の内容にする。「消灯中のsystem音声」の節の最後の文は、Task 6が判定Aなら1つ目、判定B（Task 7を行った）なら2つ目を使う:

````markdown
---
name: daemon-realtest
description: capture-daemonとserveをCLIで起動し、生音声の書き込み、区切り、serveとcapture-daemonの強制終了からの回復、消灯中のsystem音声の取り込みを実機で確かめる（GUIのappを使わない）
---

# daemon-realtest — capture-daemonとserveの実機検証（CLI）

**原則**: 実機検証はclaudeが自律的に行う。userに頼むのは物理操作（AirPodsの抜き差し、ロックの解除）と、画面や音が変わることの了承だけ。

## 事前の確認（毎回）

- Notetake.appを止める（`pgrep -x Notetake`、動いていれば`.claude/skills/mac-app/scripts/ntmenu.sh "終了"`）。appのcapture-daemonとserveが同じ状態ファイルを使うため、並べて動かさない。scriptは、Notetake.appかnotetakedが動いていれば何もせずに終わる
- `make daemon`の完了を待ってから`.build/release/notetaked`を起動する。署名の途中で起動すると、Gatekeeperがbinaryをゴミ箱へ移す
- scriptの出力先には、まだ無いか空のdirectoryを渡す。前の結果が残っていると待ちと判定が前の結果で通ってしまうため、scriptは空でない出力先では始めない
- 前面の`sleep`は使えないため、scriptは`run_in_background`で走らせ、終了の知らせを待つ

## 置き場所

- 状態ファイル: `~/Library/Application Support/Notetake/state/`の`capture-desired.json`（serveが書く。収録中は`recording`にprefixと生音声ディレクトリ）、`capture-actual.json`（capture-daemonが1秒ごとに書く。更新時刻が心拍）、`process.heartbeat`（serve）
- 生音声: `$TMPDIR/notetake-capture/<prefix>/`の`session.json`、`<source>.pcm`（16kHz monoのFloat32、header無し）、`<source>.meta.jsonl`（`anchor`、`device`、`state`の行）
- 生音声の時刻ごとの量と音量: `.claude/skills/recordings/scripts/pcm-coverage.py <生音声ディレクトリ> <mic|system> [区間の秒数]`

## CLIで一巡する

`scripts/cli-cycle.sh <出力先>`（約2分、system音声で`say`が流れる）の後に`python3 scripts/cli-cycle-report.py <出力先>`。確かめる項目:

- 開始と区切りで収録が2つでき、発話が壁時計の時刻（話し始めから4秒以内）で記録される。収録中の発話に話者は付かない
- 区切りの前後でmicの生音声の時刻が続いている（取り込みを止めずに書き込み先だけを切り替える）
- serveを`kill -9`して起動し直すと、望む状態から同じ収録を引き継ぎ、`seq`を続けて書く
- capture-daemonを`kill -9`すると、serveがstatusで「capture-daemonが応答していません」を伝え、起動し直すと同じ収録へanchorを足して書き続ける
- 停止で望む状態から収録が消え、capture-daemonが書くのをやめ、`final.md`が書かれる。状態ディレクトリに一時ファイルが残らない
- 起動したprocessが終わったcapture-daemonは、自分で取り込みを止めて終える（appが落ちた後に残り、次のcapture-daemonと同じ生音声へ書くことが無い）

`FAIL`の時は、出力先の`events.log`（serveのevent）、`serve.err`、`capture.err`、`steps.log`（各段階の時刻）と、生音声の`.meta.jsonl`を読む。

## 消灯中のsystem音声

`scripts/display-sleep-check.sh <出力先>`（約3分半）。userに「画面が90秒消える。点灯後にロック画面なら解除する」と伝えてから走らせる。`coverage.txt`で、`sleep-at`から`wake-at`の間の10秒区間に音声があるかを見る。

消灯中もScreenCaptureKitはsystem音声を取り込める（消灯を防ぐ指定はしていない）。

消灯中はScreenCaptureKitがsystem音声を取り込めないため、capture-daemonはsystem音声が鳴っている間（最後の音から5分）だけ`PreventUserIdleDisplaySleep`のassertionを持つ。`pmset -g assertions`に`Notetake: system音声を取り込んでいます`が出る。

## 固定した入力機器が外れた時（物理操作が要る）

`serve --input-device <UID>`（appではライブパネルの「入力デバイス」）でAirPodsなどに固定して収録し、`blueutil --disconnect <MAC>`（または外す）。`mic.meta.jsonl`に既定の入力の`device`行が足され、`capture-actual.json`のmicが`fell_back_from_pinned: true`になり、serveが`input_reset` eventを1回だけ出す。UIDは`.claude/skills/mac-app/scripts/audioin.sh`で調べる
````

- [ ] **Step 3: recordingsのskillを直す**

`.claude/skills/recordings/SKILL.md`の箇条書きのうち、次の2行を置き換える。前:

```markdown
  - `speaker_name` recordはprofile由来（capture初出）またはrename
```

```markdown
- 分離の遅延目安: `received_at - end`（`ruby -rjson`で算出）
```

後:

```markdown
  - `speaker_name` recordは命名の記録。収録中の発話には話者が付かない（segに`speaker`が無い）
```

```markdown
- 文字起こしの遅延の目安: `received_at - end`（`ruby -rjson`で算出）
- 生音声: `scripts/pcm-coverage.py <生音声ディレクトリ> <mic|system> [区間の秒数]`で、壁時計の区間ごとの音声の量と音量を見る。生音声ディレクトリは`$TMPDIR/notetake-capture/<prefix>/`
```

`.claude/skills/recordings/SKILL.md`の`description`。`.speakers.json`は書かれなくなり、収録中の発話に話者は付かない。前:

```markdown
description: 収録の成果物（<prefix>.final.md / .timed.jsonl / .speakers.json / orphans.jsonl）とdaemonログを読み、機器・source・話者・追記の有無を要約する。実機検証の合否判定に使う
```

後:

```markdown
description: 収録の成果物（<prefix>.final.md / .timed.jsonl / orphans.jsonl）と生音声、daemonログを読み、機器・source・追記の有無を要約する。実機検証の合否判定に使う
```

`AGENTS.md`の8行目。`mac-app`の話者命名の操作は無くなり、`daemon-realtest`の記載が無い。前:

```markdown
- 決定論的な作業はproject skillを使う: `verify` / `mac-app`（appの起動・メニュー・設定・話者命名の自動操作、画面撮影、既定入力の切替）/ `device`（iPhone / Watchのbuild・インストール・起動・crash log）/ `recordings`（収録結果の要約）
```

後:

```markdown
- 決定論的な作業はproject skillを使う: `verify` / `mac-app`（appの起動・メニュー・設定の自動操作、画面撮影、既定入力の切替）/ `device`（iPhone / Watchのbuild・インストール・起動・crash log）/ `recordings`（収録結果と生音声の要約）/ `daemon-realtest`（capture-daemonとserveのCLIでの実機検証）
```

- [ ] **Step 4: HANDOFFを直す**

`HANDOFF.md`の「状態（2026-10-03）」の最初の3項目（`- **話者分離を収録単位の確定処理へ移す。段階1を実装中**:`、`- **次の手順**:`、`- **段階1を実装する時の注意**:`とその下の箇条）を、次の2行で置き換える。かっこの中には、Task 14の結果を「CLIの一巡は全項目合格」「appのメニューに取り込みの状態が出る」「appがハングと判定したserveを止め、起動し直したserveが同じ収録を引き継ぐ」「消灯中のsystem音声は<取り込める／取り込めないため鳴っている間は消灯を防ぐ>」「固定機器の確認は<済み／未確認>」の形で書く。`/Applications/Notetake.app`の版は、Task 14のStep 6でuserが決めたものを書く:

```markdown
- **段階1（取り込みと生音声）実装済み・`make verify`通過・実機確認（Task 14の結果）**: spec `docs/superpowers/specs/2026-10-03-batch-finalize-redesign-design.md`、plan `docs/superpowers/plans/2026-10-03-capture-and-raw-audio.md`、branch `batch-finalize-redesign`。段階1と段階2の間は、収録中も停止後も`final.md`に話者が付かない。`/Applications/Notetake.app`は<段階1の版／mainの版>
- **次の手順**: 段階2（確定処理）の計画を`docs/superpowers/plans/`へ書き、userの承認を得てから実装する
```

その次の行と、その下の4行のうち最後の1行。前:

```markdown
- **mainに残る不具合（specの段階1・2で直す）**:
```

```markdown
  - tmpの生音声が削除されない。状態ディレクトリにheartbeatの一時ファイルが残る
```

後:

```markdown
- **mainに残る不具合（branchの段階1で直した。mainへはまだ入れていない）**:
```

```markdown
  - 状態ディレクトリにheartbeatの一時ファイルが残る（生音声はOSの一時ディレクトリの掃除に任せる設計のため、削除しないのは不具合ではない）
```

`- **環境**: 開発機はApple M4 Pro`で始まる行の次に足す。1行目はTask 6で分かったことで書き換える（消灯で止まるか、点灯からどれだけで戻るか、無音の間もbufferを渡すか）:

```markdown
- **ScreenCaptureKitのsystem音声**: （Task 6で分かった性質）
- **使われなくなった状態ファイル**: `~/Library/Application Support/Notetake/state/`の`capture-command.json`、`capture-event.json`、`capture.heartbeat`、`current-session.json`と、`.tmp-`を含む一時ファイルは、どのprocessも読まない。手で消してよい
```

`### 1. 区切る（R）`の1のCLIのe2eのcode blockを、次のcode blockで置き換える:

```bash
.claude/skills/daemon-realtest/scripts/cli-cycle.sh <出力先>      # 約2分。run_in_backgroundで走らせる
python3 .claude/skills/daemon-realtest/scripts/cli-cycle-report.py <出力先>
```

`### 2. 話者分離（M3）`の見出しから、`### 3. polish（M4）`の直前までを消す（収録中の話者分離は無くなった。確定処理の確認は段階2で足す）。

「申し送り」の2項目。`- **FluidAudioの推論負荷**:`で始まる行を消す。`- **ネットワークが要る初回処理**:`の行から`FluidAudioモデル（Hugging Face）、`を消す。

「設計上の割り切り・既知の未実装」から、次の5行を消す:

```markdown
- 話者分離: specの「本文を即表示して後から話者だけ差し替え」は採らず、`Aligner`で最大12秒保留してから話者付きで出す（timed.jsonlにはfinalだけ書く原則を保つため）
- `SpeakerRegistry`は1回のserve起動の間だけ`g<N>`を保持。命名していない話者はserve再起動で`g1`から振り直し（命名済みは大域プロファイルで引き継ぐ）
- `levelForPiece`: pieceの時間範囲にbufferが無い時のfallback `-120`は未対応
- daemon再起動後に同じ接頭辞で収録を再開する要件（spec）は未実装
- Transcriber: 変換ごとの`AudioConverter.reset()`が認識品質に与える影響のA/B未実施
```

「いま動くもの（使い方）」のCLIと出力の2行。前:

```markdown
- CLI: `make daemon` → `.build/release/notetaked`。subcommand: `serve`（stdin `{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdout `{"ev":"status"|"utterance"|"volatile"|"peer"|"error"|"log",...}`、`--diarize/--no-diarize`、`--pair-code`）/ `render <timed.jsonl>` / `polish <timed.jsonl>` / `transcribe <audio file>` / `capture --source mic|system --seconds N`
- 出力: `<prefix>.live.txt` / `.timed.jsonl` / `.final.md` / `.speakers.json` / `.polished.md`、`orphans.jsonl`
```

後:

```markdown
- CLI: `make daemon` → `.build/release/notetaked`。subcommand: `capture-daemon`（望む状態のファイルに従って生音声を書く）/ `serve`（stdin `{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdout `{"ev":"status"|"utterance"|"volatile"|"peer"|"error"|"log"|"input_reset",...}`、`--pair-code`）/ `render <timed.jsonl>` / `polish <timed.jsonl>` / `transcribe <audio file>`
- 出力: `<prefix>.live.txt` / `.timed.jsonl` / `.final.md` / `.polished.md`、`orphans.jsonl`。生音声は`$TMPDIR/notetake-capture/<prefix>/`
```

`### branchに入っているもの（段階順 = 検証順）`の表から、段階の列が`M3`で内容が話者分離の行（`NotetakeDiarization`、`Diarizer`、`Aligner`、`SpeakerRegistry`、`--diarize/--no-diarize`を挙げた行）を消す。

`### 4. iPhone（M5）`の7番目。前:

```markdown
7. iPhone側の話者分離（埋め込み送信）は未実装（specのM5後半）。`NotetakeDiarization`はiOS 17+対応なので、Macと同じ`Diarizer`を`Recorder`に足す
```

後:

```markdown
7. iPhone側の話者分離（埋め込み送信）は未実装（specのM5後半）。収録中の話者分離は段階1で取り除いた。iPhoneの発話の話者の扱いは、段階2の計画で決める
```

「環境の注意」のsystem音声の行。ScreenCaptureKitはsystem音声の無音の間もbufferを届ける（main時代の生音声4収録で、音声の秒数が、開始から最後に書いた時刻までの時間と一致した）。前:

```markdown
- system音声tapの特性: 音を出しているprocessが無い間はbufferが1つも来ない（無音のまま停止しても`Transcriber.finish()`は入力0の高速経路で戻る）
```

後:

```markdown
- system音声（ScreenCaptureKit）の特性: 音を出しているprocessが無い間も、無音のbufferが届き続ける。main時代にCoreAudio Process Tapで取っていた頃の「無い間はbufferが来ない」は当てはまらない
```

「環境の注意」の`- **メモリ**:`の行の`収録（分離あり）中に`を`収録中に`にする。

- [ ] **Step 5: 文書の表記を確かめる**

Run:

```bash
perl -CSD -Mutf8 -ne 'print "$ARGV:$.: $_" if /[\p{Han}\p{Hiragana}\p{Katakana}] [A-Za-z0-9`]|[A-Za-z0-9`] [\p{Han}\p{Hiragana}\p{Katakana}]/; close ARGV if eof' README.md .claude/skills/daemon-realtest/SKILL.md .claude/skills/recordings/SKILL.md .claude/skills/mac-app/SKILL.md
```

Expected: この作業で足した行が出ない（既存の行は直さない）

HANDOFF.mdとAGENTS.mdも同じ確認をする（HANDOFF.mdはこの作業で最も多く文を足す）:

```bash
perl -CSD -Mutf8 -ne 'print "$ARGV:$.: $_" if /[\p{Han}\p{Hiragana}\p{Katakana}] [A-Za-z0-9`]|[A-Za-z0-9`] [\p{Han}\p{Hiragana}\p{Katakana}]/; close ARGV if eof' HANDOFF.md AGENTS.md
```

Expected: この作業で足した行が出ない

README、AGENTS.md、skillsに、消した型と話者の書き出しへの参照が残っていないことを確かめる:

```bash
grep -rn -E "SpeakerRegistry|SpeakerProfile|Aligner|SpeakerTurn|Diarizer|NotetakeDiarization|CaptureCheckpoint|RawAudio(Frame|Reader|Writer|ReaderCapture)|CaptureControlChannel|CaptureCommand|CaptureEvent|CaptureStream|\bAudioCapture\b|currentSessionMarker|resolveFallbackSpeakers|inheritedSpeakerID|ProfileNameAnnouncer|fallback-diff|diarizer|--diarize|--no-diarize|speakers\.json|\.speakers" README.md AGENTS.md .claude/skills
grep -n -E "NotetakeDiarization|--no-diarize|--diarize|Diarizer|SpeakerRegistry|Aligner" HANDOFF.md
```

Expected: 1つ目は出力なし。2つ目は、`mainに残る不具合`の`SpeakerRegistry`の行（mainの不具合の記述）と、`## 状態（2026-09-25）`の過去の記録（`不合格・クラッシュ`と、`修正済み`の項目）だけが出る。現在の手順や仕様を書いた箇所には出ない

- [ ] **Step 6: commit（controller）**

```bash
git add README.md HANDOFF.md AGENTS.md .claude/skills/daemon-realtest/SKILL.md .claude/skills/recordings/SKILL.md
git commit -m "$(cat <<'MSG'
docs: describe stage 1 capture and live transcription

README, HANDOFF and the daemon-realtest and recordings skills now
describe the raw audio directory, the desired and actual state files,
capture state in the menu, the CLI cycle and display sleep checks, and
the transcription-only live pipeline.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
MSG
)"
```

- [ ] **Step 7: 報告して止まる**

userへ、段階1の結果（実機確認の合否と気づき）と「N commitが未push」を報告し、段階2の計画に進むかを尋ねる。pushとPRはuserの指示があるまで行わない。
