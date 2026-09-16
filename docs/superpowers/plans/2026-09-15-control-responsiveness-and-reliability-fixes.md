# Control Responsiveness and Reliability Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** issue #13（diarizerがビジーだとstop/rotate等の制御コマンドが長時間遅延する）、#14（収録中の既定入力デバイス変更に追随しない）、#10（`make verify`がiOS/watchOSビルド失敗時にもOKと誤表示する）、#11（iPhone `PeerClient`が`.waiting`を無視し「接続中」表示のまま復帰しない）を直す。

**Architecture:**
- (#13) `CaptureStream.ingest`が`await diarizer.feed(samples)`を直接awaitしているため、diarizerの推論が実時間より遅れるとbufferの取り込み自体が遅れ、`stop()`が待つ`feedTask?.value`の完了（＝溜まった音声を全てdiarizerへ流し切ること）が線形に遅延する。diarizerへのfeedを直列のchained `Task.detached`へ逃がして`ingest`の本流（transcriber feed / level記録 / bufferStreamのdrain）から切り離し、さらに`finishAfterFlush`でその chainを待つ処理に上限（5秒）を設け、上限超過時は残りの分離結果を待たずに確定させる（残りは話者未定のまま出る。データの取りこぼしではなく「話者タグが遅れて付かない」だけ）
- (#14) `MicCapture`が`AVAudioEngineConfigurationChangeNotification`を購読し、既定入力デバイス変更時にtapを新formatへ張り直してengineを再開する。`ServeSession.startCapture`がmicの`input`情報をstream起動時の1回きりの値でconsumer Taskへcaptureしている箇所を、event処理のたびに`InputDeviceProbe.current()`を呼び直す形にし、以後のsegmentの`input`ラベルが常に「今の」既定デバイスを反映するようにする
- (#10) `Makefile`の`verify`ターゲットの各`xcodebuild`/`swift build`/`swift test`ステップを`cmd | tee log; test ${PIPESTATUS[0]} -eq 0`の形にし、grepによる警告検出とは別にプロセス自体の終了コードを明示的に見る
- (#11) `PeerClient.handleConnectionState`の`.waiting`ケースでログ出力のみだったのを、一定回数（3回）連続して`.waiting`を観測したら`.failed`同様に`handleDisconnect`を呼び再探索させる。`ContentView.peerStatusText`の`.connecting`/`.connected`の文言をconnecting/connectedが読み分けられる表現に変える

**Tech Stack:** Swift 6（strict concurrency）、SwiftPM（`NotetakeCore` / `NotetakeDiarization` / `notetaked`）、xcodegen、GNU Make、Swift Testing

**Spec:** GitHub issues #13 #14 #10 #11（本文に原因・修正案あり）。HANDOFF.md「気づき」#7/#8/#3/#2/#4/#5/#6/#9は別途

## Global Constraints

- **このセッションはLinux（Claude Code on the web）でSwiftツールチェーンが無く`make verify`が実行できない。** 各Taskの「Run the gate」はMac側セッションで実行し、結果が出るまでHANDOFFには「未検証」と明記する。コンパイルエラーが無いことは目視でのみ確認する
- 検証ゲートは`make verify`（`swift build`警告ゼロ / `swift test` / `make app` / iOS + watchOSコンパイル）。Mac側セッションで実行し結果を全件受け取ってから追加修正する
- Swift 6 strict concurrency。新たな`@unchecked Sendable`は既存の正当化パターン（`AudioConverter`/`MicCapture`のコメント）に倣い、追加する場合は根拠をコメントで書く
- commit messageの末尾に`Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL`
- 日本語と英数字の間に空白を入れない（コメント・doc・commit message本文）

---

### Task 1: Diarizer.feedをchained Task.detachedへ逃がし、stop/rotateの待ちに上限を設ける（#13）

**Files:**
- Modify: `Sources/notetaked/Pipeline/CaptureStream.swift`

**Interfaces:**
- Consumes: 既存の`Diarizer.feed(_:) async throws -> Output?` / `Diarizer.flush() async throws -> Output?`（`Sources/NotetakeDiarization/Diarizer.swift`、変更不要）
- Produces: 挙動修正のみ（`StreamEvent`のcaseは増やさない。上限超過は`.log`イベントで報告する）

- [ ] **Step 1: `ingest`からdiarizer.feedの直接awaitを外し、chained detached taskへ渡す**

`CaptureStream`に以下のプロパティを追加する（`private var feedTask`の近く）:

```swift
    /// diarizer.feedの呼び出しを`ingest`の本流から切り離すchain。1つ前の呼び出しの完了を
    /// 待ってから次を実行することで、実時間の音声取り込み（transcriber feed / level記録）が
    /// diarizerの推論速度（実時間より遅れうる）に引きずられないようにする。turnの時刻は
    /// 呼び出し順に依存するため、chainの順序（＝ingestが呼ばれた順）を保つ
    private var diarizerChain: Task<Void, Never>?
```

`ingest(_:originMS:sampleRate:)`の末尾（現在の`guard let diarizer, let samples = converted.mono16k, !samples.isEmpty else { return }`以降）を、直接awaitする代わりに次のchunk投入だけ行うように変える:

```swift
        guard let diarizer, let samples = converted.mono16k, !samples.isEmpty else { return }
        let previous = diarizerChain
        diarizerChain = Task.detached { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.runDiarizerFeed(diarizer, samples: samples)
        }
    }

    /// chainの1コマ分。diarizerの推論（CoreML、同期・重い）はこのdetached task上で行われ、
    /// 結果の反映（aligner更新・event送出）だけ`await self.xxx`でCaptureStream actorへ戻す
    private func runDiarizerFeed(_ diarizer: Diarizer, samples: [Float]) async {
        do {
            if let output = try await diarizer.feed(samples) {
                applyDiarizerOutput(output)
            }
        } catch {
            reportDiarizerError(error)
        }
    }

    private func applyDiarizerOutput(_ output: Diarizer.Output) {
        aligner.add(turns: output.turns, coveredUntilMS: output.coveredUntilMS)
        emitDrained(nowMS: Self.nowMS())
    }

    private func reportDiarizerError(_ error: Error) {
        guard !diarizerErrorReported else { return }
        diarizerErrorReported = true
        eventContinuation?.yield(.log("diarizer feed failed: \(error)"))
    }
```

（`applyDiarizerOutput`/`reportDiarizerError`は`CaptureStream` actor上のメソッドとして呼ぶ。`runDiarizerFeed`自体はactor隔離外の`Task.detached`本体だが、`self.applyDiarizerOutput(...)`のように`self`（actor）のメソッドを`await`で呼べば、その部分だけactorへ戻って実行される）

- [ ] **Step 2: `finishAfterFlush`でchainの完了待ちに5秒の上限を設ける**

```swift
    private func finishAfterFlush() async {
        if let diarizer {
            let caughtUp = await Self.wait(for: diarizerChain, timeoutSeconds: 5)
            if !caughtUp {
                eventContinuation?.yield(
                    .log("diarizer backlog did not clear within 5s, finalizing without waiting further"))
            }
            if let output = try? await diarizer.flush() {
                aligner.add(turns: output.turns, coveredUntilMS: output.coveredUntilMS)
            }
        }
        for aligned in aligner.flush() {
            eventContinuation?.yield(
                .final(aligned, levelDBFS: levelForPiece(startMS: aligned.startMS, endMS: aligned.endMS)))
        }
        eventContinuation?.finish()
    }

    /// `task`の完了を`timeoutSeconds`まで待つ。間に合えばtrue、タイムアウトならfalseを返す
    /// （taskはキャンセルしない。バックグラウンドで完了自体は続き、`applyDiarizerOutput`が
    /// 呼ばれた時点でevent streamが既に`finish()`済みなら`eventContinuation?.yield`は無視されるだけで安全）
    private static func wait(for task: Task<Void, Never>?, timeoutSeconds: Double) async -> Bool {
        guard let task else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
```

**注意（レビュー観点）:** `diarizer.flush()`は`Diarizer` actor上で、chainの末尾task（まだ実行中かもしれない）がactorのmailboxに積んだ`feed`呼び出しより後に並ぶため、タイムアウトで待つのを諦めても`flush()`自体はchain末尾の`feed`が終わるまで実際には走らない（`await`はするが、待ち時間の長さの責務を「chainの完了を待つ」から「flushが自然に終わるのを待つ」へ移すだけになる）点に注意。それでも`stop()`全体の応答性は改善する（理由: 現状は`ingest`ループ自体がdiarizer速度に引きずられ`transcriber.feed`も遅れるため、`feedTask?.value`の完了そのものが遅い。この修正後は`feedTask`はdiarizer速度と無関係に速く終わるため、`stop()`のうち`await feedTask?.value`の部分は改善する。`finishAfterFlush`の`diarizer.flush()`待ちは残存の限界として引き続き遅れうるが、5秒の上限ログにより「効かない」ように見える無音の長時間ハングは無くなり、原因（backlog）がログに残る)。この残存限界はissue #13本文の「1（Task.detached化）はデータロスを防ぐものではない」という記載と一致するため、issueをこの実装だけでcloseせず、`finishAfterFlush`の`diarizer.flush()`待ち自体も同様にタイムアウトで打ち切る追加案をコメントで残す

- [ ] **Step 3: `finishAfterFlush`の`diarizer.flush()`自体にも同じ考え方で上限を設ける（Step 2の注意点への対応）**

`diarizer.flush()`の呼び出しも`Task { try await diarizer.flush() }`でラップし、`Self.wait(for:timeoutSeconds:)`と同様の考え方でタイムアウトを設ける。`Task<Output?, Never>`は`Task.detached`のジェネリック戻り値をそのまま使えるよう、`wait(for:timeoutSeconds:)`を`Task<T, Never>`向けにジェネリック化するか、`flush`専用の小さなヘルパーを足す（実装者判断。既存の`wait`をジェネリックにする方が簡潔）:

```swift
    private static func wait<T: Sendable>(for task: Task<T, Never>?, timeoutSeconds: Double) async -> T? {
        guard let task else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
```

Step 2で追加した`Task<Void, Never>`向けの`wait`はこのジェネリック版に統合し、呼び出し側は`if await Self.wait(...) == nil { ... }`で判定する。`diarizerChain`の完了待ちと`diarizer.flush()`の呼び出しをこのヘルパーで包み、それぞれ5秒の上限にする（合計最大10秒。長いと感じる場合は実装者判断で短くしてよいが、issueの「stop/rotateが効かないように見える」を解消できる秒数であること）

- [ ] **Step 4: `make verify`（Mac側セッションで実行）**

Run: `make verify`
Expected: 最終行`verify: OK`。このセッションでは実行できないため、Mac側セッションに引き継ぐまでは「未検証」

- [ ] **Step 5: Commit**

```bash
git add Sources/notetaked/Pipeline/CaptureStream.swift
git commit -m "$(cat <<'EOF'
fix(daemon): detach diarizer feed from the real-time ingest path and bound its drain wait

Diarizer.feed ran synchronously inside CaptureStream.ingest, so a diarization
backlog (CoreML slower than real time under load) delayed transcriber feed
and made stop()/rotate() wait for the entire backlog to drain before
returning, stalling control commands for tens of minutes (issue #13).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

実機確認（controllerがMac側セッションで行う）: 2話者・長時間の音源で分離ありrecordingをしながら「収録停止」/「区切る」を押し、反映が数秒以内であることを確認する。issue #13本文の「24時間運用でのバックログ推移」「メモリ推移」は別途計測が必要（本Taskのスコープ外、issueに残す）

---

### Task 2: MicCaptureが既定入力デバイスの変更に追随する（#14）

**Files:**
- Modify: `Sources/notetaked/Audio/MicCapture.swift`
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift`（`startCapture`のconsumer Task）

**Interfaces:**
- Consumes: `AVAudioEngineConfigurationChangeNotification`（AVFoundation）、既存の`InputDeviceProbe.current() -> InputDevice`
- Produces: 挙動修正のみ（新しい型・event caseは増やさない）

- [ ] **Step 1: `MicCapture`が設定変更通知でtapを張り直す**

```swift
// Sources/notetaked/Audio/MicCapture.swift
import AVFoundation

/// AVAudioEngine.inputNode に tap を付けてマイク入力を配信する。既定の入力デバイスが変わると
/// engineは`AVAudioEngineConfigurationChangeNotification`を送って自身を停止するため、
/// それを購読してtapを新しいformatへ張り直しengineを再開する（issue #14）。
/// `@unchecked Sendable`の根拠: `start`/`stop`は所有actor（CaptureStream）からのみ呼ばれ、
/// engineのtap callbackとconfiguration change通知はAVAudioEngineが管理するスレッド上でしか実行されない。
final class MicCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var configObserver: NSObjectProtocol?

    var format: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    init() {}

    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        installTap()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.reinstallTap()
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    /// 既定入力デバイスが変わった時（AirPods接続/切断等）に呼ばれる。engineは通知の時点で
    /// 既に内部停止しているため、新しいinputNodeのformatでtapを張り直してから再開する
    private func reinstallTap() {
        guard handler != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        engine.prepare()
        try? engine.start()
    }

    private func installTap() {
        guard let handler else { return }
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            handler(buffer)
        }
    }
}
```

- [ ] **Step 2: segmentの`input`が常に「今の」既定デバイスを反映する**

`Sources/notetaked/Pipeline/ServeSession.swift`の`startCapture()`内、次の箇所:

```swift
                let streamOwner = ownerFor(owner)
                let input: InputDevice = source == .system ? .system : InputDeviceProbe.current()
                let consumer = Task { [weak self] in
                    for await event in events {
                        await self?.handle(streamEvent: event, source: source, owner: streamOwner, input: input)
                    }
                }
```

を、micの場合は毎回`InputDeviceProbe.current()`を呼び直す形に変える:

```swift
                let streamOwner = ownerFor(owner)
                let inputAt: @Sendable () -> InputDevice =
                    source == .system ? { .system } : { InputDeviceProbe.current() }
                let consumer = Task { [weak self] in
                    for await event in events {
                        await self?.handle(
                            streamEvent: event, source: source, owner: streamOwner, input: inputAt())
                    }
                }
```

`self.currentInput = started.first(where: { $0.source == .mic })?.input`（`RunningStream.input`を使っている行）はそのまま残してよい（収録開始/rotate直後のstatus表示用スナップショット。ライブでの表示更新はissue #14本文の「入力インジケーター」案と合わせて別issueとする）。`RunningStream.input`に渡す値は現状どおり`startCapture`実行時点の`InputDeviceProbe.current()`でよい（このフィールドはstatus送出専用で、segmentの`input`ラベルはStep 2の`inputAt()`が別途担う）

- [ ] **Step 3: `make verify`（Mac側セッションで実行）**

Run: `make verify`
Expected: 最終行`verify: OK`。このセッションでは未検証

- [ ] **Step 4: Commit**

```bash
git add Sources/notetaked/Audio/MicCapture.swift Sources/notetaked/Pipeline/ServeSession.swift
git commit -m "$(cat <<'EOF'
fix(daemon): follow default input device changes during recording

MicCapture captured the input format once at start and never re-tapped, so
switching the default microphone (e.g. connecting/removing AirPods) silently
stopped feeding audio. Subscribe to AVAudioEngineConfigurationChangeNotification
and re-install the tap on format change; re-probe the current input device
per segment instead of once at capture start (issue #14, item 1 only —
explicit device selection and a live level meter from the issue are left
for follow-up).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

実機確認（controllerがMac側セッションで行う）: 内蔵マイクで収録開始→AirPods Proを接続（既定入力が自動で切り替わる）→話す→止めずに文字起こしが続く、以後のsegmentの`input.name`がAirPodsに変わる。外すと内蔵マイクへ自動で戻ることも確認する。issue #14の項目2（明示的なデバイス選択）・項目3（入力レベルのリアルタイム表示）は本Taskのスコープ外として issue に残す

---

### Task 3: `make verify`が各ビルドstepの終了コードを明示的に見る（#10）

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: `verify`ターゲットの各ステップに`PIPESTATUS`チェックを追加**

```make
verify:
	mkdir -p $(LOGS)
	swift build 2>&1 | tee $(LOGS)/verify-build.log; test $${PIPESTATUS[0]} -eq 0
	! grep -E $(DIAG) $(LOGS)/verify-build.log
	swift test 2>&1 | tee $(LOGS)/verify-test.log; test $${PIPESTATUS[0]} -eq 0
	$(MAKE) app 2>&1 | tee $(LOGS)/verify-app.log; test $${PIPESTATUS[0]} -eq 0
	! grep -E $(DIAG) $(LOGS)/verify-app.log
	xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' \
	  -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build 2>&1 | tee $(LOGS)/verify-ios.log; test $${PIPESTATUS[0]} -eq 0
	! grep -E $(DIAG) $(LOGS)/verify-ios.log
	@echo "verify: OK"
```

（`$$`はMakefile内で`$`をエスケープした表記。生成されるshellコマンドは`... | tee log; test ${PIPESTATUS[0]} -eq 0`になる。`.SHELLFLAGS := -eo pipefail -c`の`-e`により`test`が非0を返すとその行（＝そのmakeレシピの1行）が失敗しmakeが停止する）

- [ ] **Step 2: 再現・確認（Mac側セッションで実行、可能なら）**

watchOS Simulatorランタイムを一時的に外す、または`NotetakeMobile`スキームの`generic/platform=iOS`ビルドを意図的に壊せる状況があれば、修正前後で`make verify`のexit codeを比較する（修正前: 0のまま進む／修正後: 非0で`verify`が該当ステップで停止する）。再現条件が用意できない場合は、`Makefile`のロジックのレビューのみで足りるとし、HANDOFFに「再現未実施、ロジックレビューのみ」と明記する

- [ ] **Step 3: `make verify`が正常系で通ることを確認（Mac側セッションで実行）**

Run: `make verify`
Expected: 最終行`verify: OK`（既存の正常系が壊れていないこと）。このセッションでは未検証

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "$(cat <<'EOF'
fix(build): check each verify step's own exit code, not just its log for compiler diagnostics

The verify target judged success only by grepping build logs for compiler
warning/error lines, so an xcodebuild failure that never reaches the
compiler (e.g. a missing watchOS Simulator runtime) went undetected and
verify printed OK. Check PIPESTATUS after every piped step explicitly
(issue #10).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

---

### Task 4: iPhoneのPeerClientが`.waiting`から再接続し、接続状態の表示を明確にする（#11）

**Files:**
- Modify: `Apps/NotetakeMobile/PeerClient.swift`
- Modify: `Apps/NotetakeMobile/ContentView.swift`

**Interfaces:**
- Consumes: 既存の`NWConnection.State.waiting(NWError)`
- Produces: 挙動・表示文言の修正のみ

- [ ] **Step 1: `.waiting`を一定回数観測したら再接続する**

`PeerClient`に連続waiting回数を数えるプロパティを足す（`private var backoffSeconds`の近く）:

```swift
    /// `.waiting`が連続何回観測されたか。ネットワーク変更で到達不能になった接続は
    /// `.failed`ではなく`.waiting`のまま留まることが多いため、これが閾値に達したら
    /// `.failed`と同様に扱い再接続する（issue #11）
    private var consecutiveWaitingCount = 0
    private static let waitingThreshold = 3
```

`handleConnectionState(_:description:)`を変更:

```swift
    private func handleConnectionState(_ newState: NWConnection.State, description: String) async {
        switch newState {
        case .ready:
            consecutiveWaitingCount = 0
            state = .connected(description)
            backoffSeconds = 1
            send(.hello(hello))
            startReceiving()
            await resendPending()
        case .waiting(let error):
            Diag.log("peer client: waiting \(error)")
            consecutiveWaitingCount += 1
            if consecutiveWaitingCount >= Self.waitingThreshold {
                consecutiveWaitingCount = 0
                handleDisconnect(reason: "\(error)")
            }
        case .failed(let error):
            handleDisconnect(reason: "\(error)")
        case .cancelled:
            handleDisconnect(reason: "cancelled")
        default:
            break
        }
    }
```

`handleDisconnect(reason:)`内で`consecutiveWaitingCount`もリセットする（`receiveBuffer.removeAll()`の近くに`consecutiveWaitingCount = 0`を足す）。`.waiting`から`handleDisconnect`を呼ぶと`current.cancel()`されるが、cancel自体もいずれ`.cancelled`状態を発火しうるため、`handleDisconnect`の`guard let current = connection else { return }`と`connection = nil`の順序はそのままでよい（2回目の呼び出しは早期returnする）

- [ ] **Step 2: `ContentView.peerStatusText`の文言をconnecting/connectedで読み分けられるようにする**

```swift
    private var peerStatusText: String {
        switch model.peerState {
        case .idle: return "未接続"
        case .browsing: return "検索中…"
        case .connecting(let name): return "接続試行中: \(name)"
        case .connected(let name): return "接続済み: \(name)"
        case .failed(let reason): return "エラー: \(reason)"
        }
    }
```

- [ ] **Step 3: `make verify`（Mac側セッションで実行）**

Run: `make verify`
Expected: 最終行`verify: OK`（iOSコンパイルのみ影響）。このセッションでは未検証

- [ ] **Step 4: Commit**

```bash
git add Apps/NotetakeMobile/PeerClient.swift Apps/NotetakeMobile/ContentView.swift
git commit -m "$(cat <<'EOF'
fix(ios): recover from NWConnection .waiting after network change, clarify connecting vs connected

PeerClient logged .waiting but never transitioned state, so a connection
that became unreachable after a network change (Wi-Fi switch) stayed
"connecting" forever with no reconnect. Treat 3 consecutive .waiting
observations like .failed. Also disambiguate the connecting/connected
Japanese labels in ContentView, which read the same at a glance (issue #11).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

実機確認（controllerがMac側セッションで行う）: iPhoneとMacを接続→iPhoneのWi-Fiをゲスト/4Gへ切替→数秒〜十数秒で「検索中…」に戻り再接続を試みることを確認する（issue #11本文の再現手順）

---

## 完了後にHANDOFF.mdへ書くこと

- 本Taskで直した4件（#13 #14 #10 #11）は**全て未検証**（このセッションはLinuxでSwiftツールチェーンが無く`make verify`/実機確認ができない）。Mac側セッションで`make verify`と各Taskの実機確認を行ってから「実装済み」とすること
- #13は「制御コマンドの応答性」のみを直すもので、issue本文が指摘する「24時間運用でのバックログ・メモリ推移の未検証」「データロスのリスク（プロセス分離等の設計判断）」は未対応のまま issue に残す
- #14はissue本文の項目1（自動追随）のみ対応。項目2（明示的デバイス選択）・項目3（入力レベルのリアルタイム表示）は未対応のまま issue に残す
