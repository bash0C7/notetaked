# Device Verification Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 2026-09-13夜の実機・UI検証で見つかった3件（再起動後に話者名が引き継がれない / Watch appが録音開始で落ちる / iPhone appがstderr切断で落ちる）を直し、`make verify`を通す。

**Architecture:** (a) `SpeakerRegistry`のprofile由来の名前を、global idがそのcaptureで初めて出た時に`rename_speaker`と同じ経路（`SpeakerNameRecord`をtimed.jsonlへ追記→`Reconciler.apply(.speakerName)`）で流す。初出判定は`NotetakeCore`の小さな値型`ProfileNameAnnouncer`に持たせてテストする。(b) `WatchRecorder`のtap closureを`@Sendable`と明示してMainActor隔離の推論を外す。(c) iPhone appの診断出力を`Diag.log(_:)`（`os.Logger`＋`fputs(stderr)`、`SIGPIPE`無視）に集約し、Foundationの`NSFileHandle`例外経路を通さない。

**Tech Stack:** Swift 6（strict concurrency）、SwiftPM（`NotetakeCore` / `notetaked`）、xcodegen、Swift Testing

**Spec:** `HANDOFF.md`「状態」の「不合格・クラッシュ（2026-09-13夜）」(a)(b)(c)。根拠のcrash logは`NotetakeWatch-2026-09-13-233416.ips`（`closure #1 in WatchRecorder.start()`、`EXC_BREAKPOINT`）と`NotetakeMobile-2026-09-13-233335.ips`（`PeerClient.state.didset`→`-[NSConcreteFileHandle writeData:]`→`SIGABRT`）

## Global Constraints

- 検証ゲートは`make verify`（`swift build`警告ゼロ / `swift test` / `make app` / iOS + watchOSコンパイル）。修正はゲートの結果を全件受け取ってから行う
- `make verify`を通していないものをHANDOFFで「実装済み」と書かない
- Swift 6 strict concurrency。`@unchecked Sendable`を新たに足さない
- commit messageの末尾に`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01U7xtJbouFTgMnjJcgGfoM4`
- 日本語と英数字の間に空白を入れない（コメント・doc）

---

### Task 1: profile由来の話者名をcapture初出時に発話へ流す

**Files:**
- Create: `Sources/NotetakeCore/Speaker/ProfileNameAnnouncer.swift`
- Create: `Tests/NotetakeCoreTests/ProfileNameAnnouncerTests.swift`
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift`（`startCapture`の`self.reconciler = Reconciler()`付近、`handleFinal`の`registry.assign`直後）

**Interfaces:**
- Consumes: `SpeakerRegistry.name(for:) -> String?`（`Sources/NotetakeCore/Speaker/SpeakerRegistry.swift:66`）、`SpeakerNameRecord(speaker:name:)`（`Sources/NotetakeCore/Model/Record.swift:37`）、`Reconciler.apply(_:) -> [Utterance]`（`.speakerName` / `.segment`）、`SessionStore.append(.speakerName(_))`
- Produces: `public struct ProfileNameAnnouncer: Sendable { public init(); public mutating func record(for globalID: String, in registry: SpeakerRegistry) -> SpeakerNameRecord? }` — 同じglobal idについて最初の1回だけ、registryに名前があれば`SpeakerNameRecord`を返す。名前が無ければnilを返し「初出」も消費しない（後で命名された場合は`rename_speaker`が流すので二重にはならない）

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NotetakeCoreTests/ProfileNameAnnouncerTests.swift
import Testing

@testable import NotetakeCore

@Test func namedProfileIsAnnouncedOncePerCapture() {
    let registry = SpeakerRegistry(profiles: [
        SpeakerProfile(id: "g1", name: "Kyoko", centroid: [1, 0, 0, 0], count: 3)
    ])
    var announcer = ProfileNameAnnouncer()

    #expect(announcer.record(for: "g1", in: registry) == SpeakerNameRecord(speaker: "g1", name: "Kyoko"))
    #expect(announcer.record(for: "g1", in: registry) == nil)
}

@Test func unnamedProfileIsNotAnnouncedAndStaysPending() {
    var registry = SpeakerRegistry(profiles: [
        SpeakerProfile(id: "g1", name: nil, centroid: [1, 0, 0, 0], count: 3)
    ])
    var announcer = ProfileNameAnnouncer()

    #expect(announcer.record(for: "g1", in: registry) == nil)
    registry.setName("Kyoko", for: "g1")
    // 命名前に見た idでも、名前が付いた後の初回は返す（renameの経路と重なるのはrename側が同じrecordを流すだけで無害）
    #expect(announcer.record(for: "g1", in: registry) == SpeakerNameRecord(speaker: "g1", name: "Kyoko"))
    #expect(announcer.record(for: "g1", in: registry) == nil)
}

@Test func unknownIDIsNil() {
    let registry = SpeakerRegistry()
    var announcer = ProfileNameAnnouncer()
    #expect(announcer.record(for: "g9", in: registry) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProfileNameAnnouncerTests`
Expected: コンパイルエラー（`ProfileNameAnnouncer`未定義）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NotetakeCore/Speaker/ProfileNameAnnouncer.swift
/// `SpeakerRegistry`のprofileに保存された話者名を、そのcapture（timed.jsonl 1本）の中で
/// global idが初めて出た時に1回だけ`SpeakerNameRecord`として流すための判定。
/// `rename_speaker`（ユーザーの命名）と同じrecordを同じ経路で流すので、`Reconciler`と`render`は
/// 命名の出所を区別しなくてよい。名前の無いidは「未告知」のまま残し、後から名前が付いた時の初回に返す。
public struct ProfileNameAnnouncer: Sendable {
    private var announced: Set<String> = []

    public init() {}

    public mutating func record(for globalID: String, in registry: SpeakerRegistry) -> SpeakerNameRecord? {
        guard !announced.contains(globalID), let name = registry.name(for: globalID) else { return nil }
        announced.insert(globalID)
        return SpeakerNameRecord(speaker: globalID, name: name)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProfileNameAnnouncerTests`
Expected: 3 tests PASS

- [ ] **Step 5: Wire into ServeSession**

`Sources/notetaked/Pipeline/ServeSession.swift`:
1. fieldを追加: `private var nameAnnouncer = ProfileNameAnnouncer()`（`private var registry: SpeakerRegistry`の近く）
2. `startCapture`で`self.reconciler = Reconciler()`の直後に`self.nameAnnouncer = ProfileNameAnnouncer()`（captureごとにやり直す。rotateでも新しいfileに名前recordが入る）
3. `handleFinal`で`registry.assign`の直後、`Segment`を作る前に:

```swift
        var speaker: SpeakerTag?
        var profileName: SpeakerNameRecord?
        if let local = piece.localSpeaker, let embedding = piece.embedding {
            let global = registry.assign(
                streamKey: source.rawValue, localID: local, embedding: embedding)
            speaker = SpeakerTag(local: local, global: global, embedding: embedding)
            profileName = nameAnnouncer.record(for: global, in: registry)
        }
```

4. `store.append(.segment(segment))`の**前**に、名前recordを先に追記してreconcilerへ適用する（segmentのutteranceが最初から名前付きで出るため。timed.jsonl上でもrecordがsegより前に並び`render`が同じ結果になる）:

```swift
        if let profileName {
            do {
                try await store.append(.speakerName(profileName))
            } catch {
                await control.send(.error("failed to append speaker name: \(error)"))
                return
            }
            for utterance in reconciler.apply(.speakerName(profileName)) {
                await control.send(.utterance(utterance))
            }
        }
```

`renameSpeaker`は変更しない（ユーザー命名は従来通り。`nameAnnouncer`には触れない。同じidに対して後からrenameが来ても`Reconciler.speakerNames`が上書きされるだけ）。

- [ ] **Step 6: Run the gate**

Run: `make verify`
Expected: 最終行`verify: OK`（テスト数が164+3）

- [ ] **Step 7: Commit**

```bash
git add Sources/NotetakeCore/Speaker/ProfileNameAnnouncer.swift Tests/NotetakeCoreTests/ProfileNameAnnouncerTests.swift Sources/notetaked/Pipeline/ServeSession.swift
git commit -m "fix(daemon): announce profile-derived speaker names on first appearance in a capture so renamed voices keep their name after restart"
```

---

### Task 2: Watchのtap closureを`@Sendable`と明示する

**Files:**
- Modify: `Apps/NotetakeWatch/WatchRecorder.swift:100-105`

**Interfaces:**
- Consumes: `AsyncStream<CapturedBuffer>.Continuation`（Sendable）
- Produces: なし（挙動修正のみ）

- [ ] **Step 1: Fix the closure isolation**

`Apps/NotetakeWatch/WatchRecorder.swift`の

```swift
        // このclosureはreal-time audio threadから呼ばれる。`continuation`はSendableな値型で、
        // `self`やactorには触れないので、engineのtapとしてそのまま安全に使える。
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            continuation.yield(CapturedBuffer(buffer: buffer))
        }
```

を

```swift
        // このclosureはreal-time audio threadから呼ばれる。`AVAudioNodeTapBlock`はSDK上`@Sendable`で
        // ないため、`@MainActor`なこのクラスの中で書いたclosureはそのままだとMainActor隔離と推論され、
        // 実行時にexecutor検査で落ちる（2026-09-13の実機クラッシュ）。`@Sendable`を明示して隔離を外す。
        // `continuation`はSendableな値型で、`self`やactorには触れない。
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            continuation.yield(CapturedBuffer(buffer: buffer))
        }
```

に変える。他は変えない。

- [ ] **Step 2: Run the gate**

Run: `make verify`
Expected: `verify: OK`（watchOSはiOSビルドに埋め込みでコンパイルされる。`.build/logs/verify-ios.log`に`WatchRecorder.swift`の警告が無い）

- [ ] **Step 3: Commit**

```bash
git add Apps/NotetakeWatch/WatchRecorder.swift
git commit -m "fix(watch): mark the audio tap closure @Sendable so it is not inferred MainActor-isolated (crashed on the real-time thread)"
```

実機確認（controllerが行う）: Watchへ再インストール→「開始」で落ちない→20秒ごとに小片が転送される。

---

### Task 3: iPhone appの診断出力を`Diag.log`に集約する

**Files:**
- Create: `Apps/NotetakeMobile/Diag.swift`
- Modify: `Apps/NotetakeMobile/Recorder.swift`（`FileHandle.standardError.write`が10箇所）、`Apps/NotetakeMobile/PeerClient.swift`（3箇所）、`Apps/NotetakeMobile/WatchRelay.swift`（4箇所）

**Interfaces:**
- Produces: `enum Diag { static func log(_ message: String) }` — `os.Logger`（subsystem = bundle id、category `diag`、`privacy: .public`）へ出し、あわせて`fputs`でstderrへ出す。初回に`signal(SIGPIPE, SIG_IGN)`。stderrが閉じていても例外・シグナルで落ちない

- [ ] **Step 1: Create Diag**

```swift
// Apps/NotetakeMobile/Diag.swift
import Foundation
import os

/// 実機デバッグ用の診断出力。`xcrun devicectl … --console`で読めるようstderrへも出すが、
/// consoleが切れてstderrが閉じた後に`FileHandle`で書くと`NSFileHandle`例外でappが落ちる
/// （2026-09-13のクラッシュ）ため、C stdioの`fputs`と`SIGPIPE`無視で書き、あわせて
/// unified logging（Console.appで`subsystem`絞り込み）にも出す。
enum Diag {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.bash0c7.notetake.ios", category: "diag")
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    static func log(_ message: String) {
        _ = ignoreSIGPIPE
        logger.info("\(message, privacy: .public)")
        fputs(message + "\n", stderr)
    }
}
```

- [ ] **Step 2: Replace every stderr write**

`Apps/NotetakeMobile/`の`FileHandle.standardError.write(Data("<text>\n".utf8))`を全て`Diag.log("<text>")`に置き換える（末尾の`\n`は`Diag.log`が付ける）。例:

```swift
// before
FileHandle.standardError.write(Data("peer client: \(state)\n".utf8))
// after
Diag.log("peer client: \(state)")
```

確認: `grep -rn 'FileHandle.standardError' Apps/NotetakeMobile Apps/NotetakeWatch`が0件。

- [ ] **Step 3: Run the gate**

Run: `make verify`
Expected: `verify: OK`

- [ ] **Step 4: Commit**

```bash
git add Apps/NotetakeMobile/Diag.swift Apps/NotetakeMobile/Recorder.swift Apps/NotetakeMobile/PeerClient.swift Apps/NotetakeMobile/WatchRelay.swift
git commit -m "fix(ios): route diagnostics through Diag.log (os.Logger + fputs, SIGPIPE ignored) so a closed stderr no longer aborts the app"
```

実機確認（controllerが行う）: `--console`付きで起動→consoleを切る→機内モードON/OFFで`PeerClient.state`が変わっても落ちない。
