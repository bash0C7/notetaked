# 段階Lの検証ゲートと是正 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make verify`（全targetのビルド・警告ゼロ・全テスト・iOS / watchOSコンパイル）を定義し、段階L / M6のコードがそれを通る状態にする。

**Architecture:** Makefileに`verify`を1本足し、以降の全タスクはその結果を全件受け取ってから直す。Watch側の並行性エラー2群（`ChunkWriter` init、`WatchRelay.WatchStream`）を構造で解く。iPhone側の時刻基準をNotetakeCoreの純粋な`SampleClock`に統一し、テストで固定する。最後にHANDOFF / CLAUDE.md / 段階L planのチェックボックスを事実に合わせる。

**Tech Stack:** Swift 6（strict concurrency）、SwiftPM、swift-testing、xcodegen、xcodebuild、GNU make（bash）

**Spec:** `docs/superpowers/specs/2026-09-13-stage-l-verification-remediation-design.md`（親spec `2026-09-13-spatial-location-polish-design.md`）

## Global Constraints

- 署名: daemon / mac appはad-hoc（`DAEMON_IDENTITY ?= -`、`CODE_SIGN_IDENTITY: "-"`）。iOS / watchOSは`CODE_SIGNING_ALLOWED=NO`でコンパイルのみ。失効証明書で署名しない
- `-warnings-as-errors`は使わない。警告ゼロはgrep（`\.swift:[0-9]+:[0-9]+: (warning|error):`）で判定する
- 修正はゲート（`make verify`、またはタスク内で指定した部分コマンド）の結果を全件受け取ってから行う。1件ずつ潰さない
- `WatchStream`に`@unchecked Sendable`を足さない。隔離境界を越える音声bufferの受け渡しは、既存の`Recorder.CapturedBuffer`（`@unchecked Sendable`の値型wrapper、根拠付き）に倣う
- モデル分担: コード記述 = Sonnet、コマンド実行 = Haiku、task review = Sonnet。xcodebuildのpackage解決がBash sandbox内で止まる場合はsandbox外（controller本体）で実行する
- commitはタスクごとに1つ、末尾に`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01U7xtJbouFTgMnjJcgGfoM4`
- 日本語と英数字の間に空白を入れない
- ledger: `.superpowers/sdd/2026-09-13-stage-l-verification-remediation/progress.md`（git管理外）

## File Structure

- Modify `Makefile` — `verify` target（Task 1）
- Modify `Sources/notetaked/Pipeline/CaptureStream.swift`、`Tests/NotetakeCoreTests/PolishRendererTests.swift`、`Tests/NotetakeCoreTests/DirectionEstimatorTests.swift`、`docs/superpowers/plans/2026-09-13-spatial-location-polish.md` — 適用済み差分のcommit（Task 2）
- Modify `Apps/NotetakeWatch/WatchRecorder.swift` — `ChunkWriter.openFile`（Task 3）
- Modify `Apps/NotetakeMobile/WatchRelay.swift` — `creating: [String: Task<Void, Never>]`（Task 4）
- Create `Sources/NotetakeCore/Audio/SampleClock.swift`、`Tests/NotetakeCoreTests/SampleClockTests.swift`; Modify `Apps/NotetakeMobile/Recorder.swift`（Task 5）
- Modify `HANDOFF.md`、`CLAUDE.md`、`docs/superpowers/plans/2026-09-13-spatial-location-polish.md`（チェックボックス）、本plan（Task 6）

---

### Task 1: `make verify`

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Produces: `make verify`。成功時に最終行`verify: OK`、失敗時は非0で停止。ログは`.build/logs/verify-*.log`

- [x] **Step 1: Makefileに`verify`を足す**

`Makefile`全体を次にする（既存targetは据え置き、`SHELL` / `.SHELLFLAGS` / `LOGS` / `DIAG` / `verify`を追加）。

```make
# set DAEMON_IDENTITY=<SHA-1 of a valid "Apple Development" identity> once the certificate is renewed
DAEMON_IDENTITY ?= -
DERIVED := .build/DerivedData
LOGS := .build/logs
# compiler diagnostics with a file position; tool-level notices (e.g. AppIntents metadata) do not match
DIAG := '\.swift:[0-9]+:[0-9]+: (warning|error):'

SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c

.PHONY: test daemon project app verify clean

test:
	swift test

daemon:
	swift build -c release --product notetaked \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/notetaked/Info.plist
	codesign --force --sign "$(DAEMON_IDENTITY)" --identifier io.github.bash0c7.notetaked .build/release/notetaked

project:
	cd Apps && xcodegen generate

app: daemon project
	xcodebuild -project Apps/Notetake.xcodeproj -scheme Notetake -configuration Debug -derivedDataPath $(DERIVED) build

# The single verification gate: every target compiles warning-free, all tests pass,
# the mac app builds, and the iOS app (with the embedded watch app) compiles without signing.
verify:
	mkdir -p $(LOGS)
	swift build 2>&1 | tee $(LOGS)/verify-build.log
	! grep -E $(DIAG) $(LOGS)/verify-build.log
	swift test 2>&1 | tee $(LOGS)/verify-test.log
	$(MAKE) app 2>&1 | tee $(LOGS)/verify-app.log
	! grep -E $(DIAG) $(LOGS)/verify-app.log
	xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' \
	  -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build 2>&1 | tee $(LOGS)/verify-ios.log
	! grep -E $(DIAG) $(LOGS)/verify-ios.log
	@echo "verify: OK"

clean:
	rm -rf .build Apps/Notetake.xcodeproj
```

- [x] **Step 2: ゲートが現状の失敗を出すことを確認する**

Run: `make verify 2>&1 | tail -20; echo EXIT=$?`
Expected: `swift build`は通り、`swift test`のコンパイルで落ちる（Task 2の差分がまだ未commitでworktreeに残っているなら、`swift test`は通り、iOSビルドの`WatchRecorder.swift:282`で落ちる）。いずれにせよ`verify: OK`は出ず、EXITは非0。

- [x] **Step 3: Commit**

```bash
git add Makefile
git commit -m "build: add make verify as the single verification gate (build warning-free, tests, mac app, iOS+watchOS compile)"
```

---

### Task 2: 適用済み差分（問題1・2・3）のcommit

**Files:**
- Modify（適用済み）: `Sources/notetaked/Pipeline/CaptureStream.swift:135,146`（`await`除去）、`Tests/NotetakeCoreTests/PolishRendererTests.swift:42`（`polishedMarkdownOfNoTurnsIsEmpty`）、`Tests/NotetakeCoreTests/DirectionEstimatorTests.swift:10`（`- 1`）、`docs/superpowers/plans/2026-09-13-spatial-location-polish.md`（同じ2箇所）

**Interfaces:**
- Consumes: なし
- Produces: `swift build`警告ゼロ、`swift test`全件通過

- [x] **Step 1: worktreeの差分が次の3点だけであることを確認する**

Run: `git diff --stat && git diff`
Expected: 上記4ファイル。`CaptureStream.swift`は`await self.acceptFinal(piece)`→`self.acceptFinal(piece)`と`await self.drainPending()`→`self.drainPending()`。`PolishRendererTests.swift`は`@Test func emptyIsEmpty()`→`@Test func polishedMarkdownOfNoTurnsIsEmpty()`。`DirectionEstimatorTests.swift`は`return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000`→末尾に` - 1`。planは同じ2箇所。差分が無ければ（既に戻されていれば）この内容をそのまま適用する。

- [x] **Step 2: ビルドが警告ゼロ、テストが全件通ることを確認する**

Run: `swift build 2>&1 | grep -E '\.swift:[0-9]+:[0-9]+: (warning|error):'; swift test 2>&1 | grep -E "Test run with|✘" | tail -5`
Expected: grepは出力なし。`✔ Test run with 162 tests in 0 suites passed`（件数は162以上）。`✘`なし。

- [x] **Step 3: Commit**

```bash
git add Sources/notetaked/Pipeline/CaptureStream.swift Tests/NotetakeCoreTests/PolishRendererTests.swift Tests/NotetakeCoreTests/DirectionEstimatorTests.swift docs/superpowers/plans/2026-09-13-spatial-location-polish.md
git commit -m "fix(test,daemon): unique test name, zero-mean noise in DirectionEstimator tests, drop redundant awaits in CaptureStream"
```

---

### Task 3: `ChunkWriter`のinitからactor隔離メソッドを呼ばない

**Files:**
- Modify: `Apps/NotetakeWatch/WatchRecorder.swift`（`actor ChunkWriter`、init末尾の`try openNextFile()`と`private func openNextFile()`）

**Interfaces:**
- Consumes: なし
- Produces: `ChunkWriter.init(...)`のシグネチャは変更なし（呼び出し側`WatchRecorder.swift:76`はそのまま）

- [x] **Step 1: 現状のエラーを確認する**

Run: `xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '\.swift:[0-9]+:[0-9]+: (warning|error):' | sort -u`
Expected: `Apps/NotetakeWatch/WatchRecorder.swift:282:13: error: call to actor-isolated instance method 'openNextFile()' in a synchronous nonisolated context` の1行。

- [x] **Step 2: ファイルを開く処理をnonisolatedなstatic関数に切り出す**

`ChunkWriter`のinit末尾の`try openNextFile()`を次に置き換える。

```swift
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: index, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        self.currentFile = file
        self.currentURL = url
    }
```

`private func openNextFile() throws`を次に置き換える。

```swift
    /// 非asyncなactor initはnonisolatedで隔離メソッドを呼べないため、
    /// ファイルを開く処理はstaticにしてinitと`openNextFile()`の両方から使う
    private static func openFile(
        directory: URL, session: String, index: Int, settings: [String: Any],
        commonFormat: AVAudioCommonFormat, interleaved: Bool
    ) throws -> (AVAudioFile, URL) {
        let url = directory.appendingPathComponent("\(session)-\(index).m4a")
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: commonFormat, interleaved: interleaved)
        return (file, url)
    }

    private func openNextFile() throws {
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: index, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        currentFile = file
        currentURL = url
    }
```

- [x] **Step 2b: tapからwriterへのbuffer受け渡しをwrapperで包む**

型検査を通った先のregion isolation検査で `WatchRecorder.swift:98` `continuation.yield(buffer)` と `:116` `writer.append(buffer)` が `sending 'buffer' risks causing data races` になる（生の`AVAudioPCMBuffer`を`AsyncStream`に流しているため）。iPhone側`Apps/NotetakeMobile/Recorder.swift`の`CapturedBuffer`と同じ形にする。

`final class WatchRecorder`の先頭（stored propertyの前）に追加:

```swift
    /// tap callback（audioスレッド）からfeedTaskへbufferを渡すための値型wrapper。
    /// `@unchecked Sendable`の根拠: tapはyield後にbufferへ触れず、受け取ったfeedTaskだけが読む（`Recorder.CapturedBuffer`と同じ）
    private struct CapturedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }
```

`start`内を次に変える:

```swift
        let (stream, continuation) = AsyncStream<CapturedBuffer>.makeStream()
        bufferContinuation = continuation
        // このclosureはreal-time audio threadから呼ばれる。`continuation`はSendableな値型で、
        // `self`やactorには触れないので、engineのtapとしてそのまま安全に使える。
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            continuation.yield(CapturedBuffer(buffer: buffer))
        }
```

```swift
        feedTask = Task { @MainActor [weak self] in
            for await captured in stream {
                let outcome = await writer.append(captured.buffer)
```

`bufferContinuation`のstored propertyの型を`AsyncStream<CapturedBuffer>.Continuation?`にする。他は変えない。

- [x] **Step 3: Watch targetが通り、次のエラーがWatchRelayだけになることを確認する**

Run: Step 1と同じコマンド
Expected: `WatchRecorder.swift`の行は消える。残るのは`Apps/NotetakeMobile/WatchRelay.swift`の`WatchStream`のSendable違反（111 / 189 / 193 / 199行）と`Recorder.swift:73`（`builtInMicrophone` deprecated）、`Recorder.swift:130`（不要な`await`）の警告のみ。他にWatch側のエラー・警告が出たら全件を報告してから直す。

- [x] **Step 4: Commit**

```bash
git add Apps/NotetakeWatch/WatchRecorder.swift
git commit -m "fix(watch): open the first chunk file via a static helper so ChunkWriter's nonisolated init compiles"
```

---

### Task 4: `WatchRelay`の生成Taskからactor外へ`WatchStream`を出さない

**Files:**
- Modify: `Apps/NotetakeMobile/WatchRelay.swift`（`creating`の型、`streamFor(meta:orphanFileIfFailed:)`、`buildStream(meta:)`、init、`receive`、`ensureIdleLoop`）、`Apps/NotetakeMobile/MobileModel.swift:97`（コメント1行）

**Interfaces:**
- Consumes: なし
- Produces: `streamFor`の戻り値`WatchStream?`は変更なし。`buildStream`は`async`（throwしない）で、完了時に自分で`streams`へ登録する

- [x] **Step 1: `creating`の型を変える**

`WatchRelay.swift:111`を次にする。

```swift
    /// session生成中（Transcriber起動待ち）のTask。完了したら`buildStream`が`streams`へ登録し、ここから消す。
    /// `WatchStream`は可変なclassでSendableでないため、Taskの結果としてactor外へ出さない
    private var creating: [String: Task<Void, Never>] = [:]
```

- [x] **Step 2: `streamFor`を書き換える**

`private func streamFor(meta:orphanFileIfFailed:)`の本体を次にする（直前のdocコメントは据え置き）。

```swift
    private func streamFor(meta: WatchChunkMetadata, orphanFileIfFailed url: URL) async -> WatchStream? {
        if let existing = streams[meta.session] {
            return existing
        }

        let task: Task<Void, Never>
        if let inFlight = creating[meta.session] {
            task = inFlight
        } else {
            let newTask = Task { await self.buildStream(meta: meta) }
            creating[meta.session] = newTask
            task = newTask
        }
        await task.value

        guard let stream = streams[meta.session] else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return stream
    }
```

- [x] **Step 3: `buildStream`を書き換える**

`private func buildStream(meta:) async throws -> WatchStream`を次にする。

```swift
    /// Transcriberを起動して`streams[meta.session]`へ登録する。失敗はlogして登録しない。
    /// `task.value`を待っていた複数の呼び出しが順に戻ってきても、登録と`onStreamCount`は1回だけ
    private func buildStream(meta: WatchChunkMetadata) async {
        defer { creating[meta.session] = nil }
        do {
            let originMS = meta.startAtMS
            let origin = Date(timeIntervalSince1970: Double(originMS) / 1000)
            let transcriber = try await Transcriber(locale: locale, origin: origin)
            let pieces = try await transcriber.start()

            let stream = WatchStream(transcriber: transcriber, originMS: originMS, firstMeta: meta)
            let session = meta.session
            stream.pieceTask = Task { [weak self] in
                for await piece in pieces where piece.isFinal {
                    guard !piece.text.isEmpty else { continue }
                    guard let self else { return }
                    await self.emit(piece: piece, session: session)
                }
            }
            streams[session] = stream
            onStreamCount(streams.count)
        } catch {
            logError("failed to start transcriber for session \(meta.session): \(error)")
        }
    }
```

- [x] **Step 3b: idle loopをinitではなく最初の`receive`で起動する**

ゲートで `WatchRelay.swift:128:18: error: cannot access property 'idleTask' here in nonisolated initializer` が出る。非asyncなactor initは、`self`をclosureに捕捉させた後は隔離プロパティに触れない。initからTask生成を外し、最初の小片を受け取った時に起動する（`finishAll()`で止めた後に小片が来れば再び起動する）。

initの末尾の次の4行を削除する:

```swift
        idleTask = Task { [weak self] in
            await self?.runIdleLoop()
        }
```

`receive(url:meta:)`の先頭（`guard let stream = await streamFor(...)`の前）に1行追加し、関数を1つ足す:

```swift
    func receive(url: URL, meta: WatchChunkMetadata) async {
        ensureIdleLoop()
        guard let stream = await streamFor(meta: meta, orphanFileIfFailed: url) else { return }
```

```swift
    /// idle監視は最初の小片が届いてから始める（非asyncなactor initでは`self`を捕捉するTaskを作れないため）。
    /// `finishAll()`で止めた後に小片が来れば再び起動する
    private func ensureIdleLoop() {
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            await self?.runIdleLoop()
        }
    }
```

`Apps/NotetakeMobile/MobileModel.swift:97`のコメント「（何も受信しないだけで無害。idleループが15秒おきに空のstreams辞書を見るだけ）」を「（何も受信しないだけで無害。idleループも最初の小片が届くまで動かない）」にする。

- [x] **Step 4: iOS targetのエラーが消えることを確認する**

Run: `xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '\.swift:[0-9]+:[0-9]+: (warning|error):|BUILD' | sort -u`
Expected: `error:`なし。`BUILD SUCCEEDED`。残る警告は`Recorder.swift:73`と`Recorder.swift:130`の2行のみ（Task 5で消す）。他に出たら全件を報告してから直す。

- [x] **Step 5: Commit**

```bash
git add Apps/NotetakeMobile/WatchRelay.swift
git commit -m "fix(ios): keep WatchStream inside the WatchRelay actor; creation tasks return Void"
```

---

### Task 5: `SampleClock`とiPhone側の時刻基準の統一（問題6・7・8）

**Files:**
- Create: `Sources/NotetakeCore/Audio/SampleClock.swift`
- Test: `Tests/NotetakeCoreTests/SampleClockTests.swift`
- Modify: `Apps/NotetakeMobile/Recorder.swift`（`start`、`stop`、`ingest`、73行の`.builtInMicrophone`、130行の`await`）

**Interfaces:**
- Produces: `SampleClock(originMS: Int64, sampleRate: Double)`、`ms(atFrame: AVAudioFramePosition) -> Int64`

- [x] **Step 1: 失敗するテストを書く**

`Tests/NotetakeCoreTests/SampleClockTests.swift`:

```swift
import AVFoundation
import Testing
@testable import NotetakeCore

@Test func sampleClockConvertsFramesAtInputRate() {
    let clock = SampleClock(originMS: 1_000_000, sampleRate: 16000)
    #expect(clock.ms(atFrame: 0) == 1_000_000)
    #expect(clock.ms(atFrame: 16000) == 1_001_000)
    #expect(clock.ms(atFrame: 8000) == 1_000_500)
}

@Test func sampleClockRoundsLikeTranscriber() {
    // Transcriber.makePiece: originMS + round(CMTimeGetSeconds(CMTime(value: frame, timescale: rate)) * 1000)
    let clock = SampleClock(originMS: 0, sampleRate: 16000)
    for frame: AVAudioFramePosition in [1, 7, 8, 9, 15, 16, 12345, 987_654] {
        let expected = Int64((CMTimeGetSeconds(CMTime(value: frame, timescale: 16000)) * 1000).rounded())
        #expect(clock.ms(atFrame: frame) == expected)
    }
}
```

- [x] **Step 2: 失敗を確認する**

Run: `swift test --filter SampleClock 2>&1 | grep -E "error:|✘|✔ Test run" | head`
Expected: `cannot find 'SampleClock' in scope`でコンパイルエラー。

- [x] **Step 3: `SampleClock`を実装する**

`Sources/NotetakeCore/Audio/SampleClock.swift`:

```swift
import AVFoundation

/// Transcriberの入力format（変換後）のサンプル数を壁時計ミリ秒へ換算する純粋計算。
/// Transcriberが`startMS`を作る式（origin + CMTime(sampleTime, timescale: sampleRate)）と同じ丸めにする。
/// 生マイクのサンプルレートは時刻に使わない（親spec「時刻基準」）
public struct SampleClock: Sendable {
    public let originMS: Int64
    public let sampleRate: Double

    public init(originMS: Int64, sampleRate: Double) {
        self.originMS = originMS
        self.sampleRate = sampleRate
    }

    public func ms(atFrame frame: AVAudioFramePosition) -> Int64 {
        originMS + Int64((Double(frame) / sampleRate * 1000).rounded())
    }
}
```

- [x] **Step 4: 通ることを確認する**

Run: `swift test --filter SampleClock 2>&1 | grep -E "✘|✔ Test run"`
Expected: `✔ Test run with 2 tests in 0 suites passed`

- [x] **Step 5: `Recorder`の時刻計算を`SampleClock`に統一し、警告2件を消す**

`Apps/NotetakeMobile/Recorder.swift`:

1. 73行 `AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified)` → `AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)`
2. stored propertyに`private var clock: SampleClock?`を追加（`private var originMS: Int64 = 0`の直後）
3. `start`で`self.transcriber = transcriber`の直後に `self.clock = SampleClock(originMS: originMS, sampleRate: transcriber.inputFormat.sampleRate)` を追加
4. `stop`で`self.transcriber = nil`の直後に `self.clock = nil` を追加
5. 130行 `let (level, direction) = await self.finish(piece: piece)` → `let (level, direction) = self.finish(piece: piece)`
6. `private func ingest(_ buffer: sending AVAudioPCMBuffer) async`全体を次に置き換える

```swift
    private func ingest(_ buffer: sending AVAudioPCMBuffer) async {
        guard let transcriber, let clock else { return }

        let monoSource: AVAudioPCMBuffer
        var foaChannels: (w: [Float], y: [Float], x: [Float])?
        if input.spatial, buffer.format.channelCount == 4 {
            guard let foa = try? foaBuffer(from: buffer), let data = foa.floatChannelData else { return }
            let count = Int(foa.frameLength)
            let w = Array(UnsafeBufferPointer(start: data[0], count: count))
            let y = Array(UnsafeBufferPointer(start: data[1], count: count))
            let x = Array(UnsafeBufferPointer(start: data[3], count: count))
            foaChannels = (w, y, x)
            guard let mono = Self.monoBuffer(samples: w, sampleRate: foa.format.sampleRate) else { return }
            monoSource = mono
        } else {
            monoSource = buffer
        }

        if converter == nil {
            converter = try? AudioConverter(from: monoSource.format, to: transcriber.inputFormat)
        }
        guard let converter, let converted = try? converter.convert(monoSource) else { return }
        let convertedFrames = AVAudioFramePosition(converted.frameLength)

        // 時刻はTranscriberと同じ変換後サンプル数の時計で作る（親spec「時刻基準」）
        if let foaChannels {
            estimator.add(
                w: foaChannels.w, y: foaChannels.y, x: foaChannels.x,
                startMS: clock.ms(atFrame: sampleTime),
                endMS: clock.ms(atFrame: sampleTime + convertedFrames))
        }
        lastLevelDBFS = AudioLevel.dbfs(converted)
        await transcriber.feed(converted, at: sampleTime)
        sampleTime += convertedFrames
    }
```

- [x] **Step 6: ゲート全体を通す**

Run: `make verify 2>&1 | tail -5; echo EXIT=$?`
Expected: 最終行`verify: OK`、EXIT=0。落ちたら`.build/logs/verify-*.log`から該当行を全件集めてから直す。

- [x] **Step 7: Commit**

```bash
git add Sources/NotetakeCore/Audio/SampleClock.swift Tests/NotetakeCoreTests/SampleClockTests.swift Apps/NotetakeMobile/Recorder.swift
git commit -m "fix(ios): derive direction frame times from the transcriber's sample clock (SampleClock); use .microphone; drop redundant await"
```

---

### Task 6: HANDOFF / CLAUDE.md / planのチェックボックス

**Files:**
- Modify: `HANDOFF.md`、`CLAUDE.md`、`docs/superpowers/plans/2026-09-13-spatial-location-polish.md`、本plan

- [x] **Step 1: `CLAUDE.md`に規律2行を足す**

末尾に追加:

```markdown
- 検証ゲートは`make verify`（全targetのビルド警告ゼロ・全テスト・mac app・iOS / watchOSコンパイル）。修正はゲートの結果を全件受け取ってから行う。1件ずつ潰さない
- `make verify`を通していないものをHANDOFFで「実装済み」と書かない（「未検証」と書く）
```

- [x] **Step 2: `HANDOFF.md`を事実に合わせる**

1. 「状態」: 段階Lの箇条書きを「段階L実装済み・`make verify`通過（2026-09-13）。iPhoneの実機検証（`input.spatial`、方位、FOA変換のチャンネル順）は証明書再発行後」に書き換える。2つ目の箇条書きの「`make test`と…段階1〜5は未実施」は「`make verify`通過。段階1〜5（実機・手動）は未実施」にする。「次:」は「段階1〜6の実機・手動検証を順に実行」にする。ledgerの記述は「web側のledgerはMacから読めない。Mac側のledgerは`.superpowers/sdd/2026-09-13-stage-l-verification-remediation/progress.md`」にする
2. 「branchに入っているもの」の表に行を足す: `| V 検証ゲート | `make verify`、`ChunkWriter` init / `WatchRelay`の並行性修正、`SampleClock` | `docs/superpowers/plans/2026-09-13-stage-l-verification-remediation.md` |`。段階Lの行の「**実装済み・Mac未検証**」を「`make verify`通過」に
3. 「### 0. 依存解決とビルド」のコードブロックを次にする:

```bash
swift package --disable-keychain --disable-netrc resolve   # 初回のみ。FluidAudioのbinaryTarget取得にネット必須
make verify   # swift build（警告ゼロ）→ swift test → make app → iOS+watchOSコンパイル。最終行 verify: OK
```

   直下の「原則」段落に「修正はゲートの結果を全件受け取ってから行う」を1文足す
4. 「コンパイルエラーが出やすい箇所」を、実機でしか分からないものだけに絞る: `Apps/NotetakeWatch/WatchRecorder.swift`のAAC書き出し、`Apps/NotetakeMobile/Recorder.swift`の`foaBuffer(from:)`のチャンネル順（W/Y/Z/X）と`multichannelAudioMode`の設定順序。Polisher / PeerListener / Transcriber / Diarizer / strict concurrency / RecorderのAPI名の項は削除（コンパイルで確認済み）
5. 「### 6. 場所情報 / 対話整形（L）」末尾の「未実行の検証コマンド」ブロックを削除
6. 「環境の注意」に「`make verify`はxcodebuildのpackage解決を含むためBash sandbox内では止まることがある。sandbox外で実行」を足す（既存のsandbox注記と統合してよい）
7. 「検証コマンド」節: `make verify`を先頭に足す

- [x] **Step 3: 段階L planのMac側実行待ちチェックボックスを埋める**

`docs/superpowers/plans/2026-09-13-spatial-location-polish.md`の`- [ ] ...（Mac側で実行待ち）`14箇所を`- [x]`にし、末尾の「（Mac側で実行待ち）」を「（2026-09-13 `make verify`で確認）」にする。

Run: `grep -c '^\- \[ \]' docs/superpowers/plans/2026-09-13-spatial-location-polish.md`
Expected: `0`

- [x] **Step 4: 本planのチェックボックスを埋め、ゲートを最終確認する**

Run: `make verify 2>&1 | tail -3`
Expected: `verify: OK`

- [x] **Step 5: Commit**

```bash
git add HANDOFF.md CLAUDE.md docs/superpowers/plans/2026-09-13-spatial-location-polish.md docs/superpowers/plans/2026-09-13-stage-l-verification-remediation.md
git commit -m "docs(handoff): make verify passes for stage L; verification gate and rules recorded"
```
