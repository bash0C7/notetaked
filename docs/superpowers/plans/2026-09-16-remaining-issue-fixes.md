# Remaining Issue Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** issue #7（daemon再起動後もiPhone appが「接続」表示のままでCLOSE_WAITが残る）、#8（分離結果の無い短い発話が所有者名で出て同一人物が割れる）、#6（複数デバイスの場所ラベルはlevel_dbfs最大のsegの機器にする、user決定済み）、#3（ライブパネルのtoolbar overflowが使いにくい）、#5（Macの収録開始=セッション開始、iPhoneの開始=取り込み開始、のUI・用語整理）を直す。#4（ペアリングコード方式をやめてiCloud等で自動識別）はこのセッションでは実装せず、検討結果をspecとして残す（Global Constraints参照）。

**Architecture:**
- (#7) `PeerListener.handleDisconnect`が接続をdictionaryから外すだけで`NWConnection.cancel()`を呼んでいないため、相手がFINを送ってきてもソケットがCLOSE_WAITのまま残る。`connection.cancel()`を明示的に呼ぶ。iPhone側`PeerClient`には、Mac(daemon)が接続確立後に送り続けている既存の定期ping（`ServeSession.handleHello`、60秒毎）を使った生存監視（watchdog）を追加する。一定時間（150秒 ≈ ping間隔の2.5倍）何も受信しなければ`.failed`と同様に扱い`handleDisconnect`→再browsingする。issue本文はPeerClient発のping送信を提案しているが、Macが既にpingを送り続けているため、client側は受信監視だけで同じ目的（生存確認とtimeout再接続）を達成できる（往復メッセージを増やさない分シンプル）
- (#8) `Reconciler`で新規utteranceを作る際、`seg.speaker?.global`がnilなら、同じ`device`の直前のutterance（時間差が閾値=5秒以内）の`speakerID`を継承する。継承元が無い（そのdeviceの最初の発話）か閾値を超えていればownerLabelにfallenする現状のまま。`merge`で追加segにも同じ規則を適用する
- (#6) `Utterance`に場所ラベル専用のフィールド（`locationInput` / `locationPlatform` / `locationSource` / `locationDirection` / `locationLevelDBFS`）を追加し、`merge`時に`level_dbfs`が今までの最大を上回るsegが来るたびそれらを差し替える。既存の`input` / `platform` / `source` / `direction`（本文の勝者基準、confidenceの高いdirection基準）は一切変更しない（既存テストの期待値のまま）。`LocationLabel.text(for:)`だけを新フィールド参照に変える
- (#3) `LivePanelView`の`.toolbar`から操作ボタン（収録開始/収録停止/区切る/整形/常に前面/全文コピー）を外し、本文上部の固定の横スクロール可能な`HStack`へ移す。ステータス文言だけ`.toolbar`に残す（issue本文の案2）
- (#5) `LivePanelView`のボタン文言・状態文言を「セッション開始」「セッション終了」「セッション中」「セッション無し」へ、`ContentView`（iPhone）のボタン文言を「取り込み開始」「取り込み中」へ変更し、セクション見出しも「取り込み」にする。iPhone側に「Macでセッションを開始してから使う」旨の説明文を足す。プロトコル（`HelloMessage`等）にMacの現在prefixを載せる変更はしない（サーバ側に新しい状態同期が要り、この整理の本質である文言の混同解消には不要なため今回はスコープ外とし、issueに残す）

**Tech Stack:** Swift 6（strict concurrency）、SwiftPM（`NotetakeCore` / `notetaked`）、SwiftUI（`Apps/Notetake` mac app、`Apps/NotetakeMobile` iOS app）、Swift Testing

**Spec:** GitHub issues #7 #8 #6 #3 #5（本文に原因・修正案あり）。#4は`docs/superpowers/specs/2026-09-16-icloud-pairing-design.md`（本plan完了後にcontrollerが直接作成、コード変更なし）

## Global Constraints

- **このセッションはLinux（Claude Code on the web）でSwiftツールチェーンが無く`make verify`が実行できない。** 各Taskの「Run the gate」はMac側セッションで実行し、結果が出るまでHANDOFFには「未検証」と明記する。コンパイルエラーが無いことは目視でのみ確認する
- 検証ゲートは`make verify`（`swift build`警告ゼロ / `swift test` / `make app` / iOS + watchOSコンパイル）。Mac側セッションで実行し結果を全件受け取ってから追加修正する
- Swift 6 strict concurrency。新たな`@unchecked Sendable`は既存の正当化パターンに倣い、追加する場合は根拠をコメントで書く
- commit messageの末尾に`Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL`
- 日本語と英数字の間に空白を入れない（コメント・doc・commit message本文）
- #4はコード変更を行わない（CloudKit/iCloud関連はこのセッションでは検証不可能な実機・アカウント操作が前提のため、design specの作成のみ）

---

### Task 1: PeerListenerのCLOSE_WAIT修正とPeerClientの生存監視（#7）

**Files:**
- Modify: `Sources/notetaked/Peer/PeerListener.swift`
- Modify: `Apps/NotetakeMobile/PeerClient.swift`

**Interfaces:**
- Consumes: 既存の`PeerMessage.ping`/`ServeSession`の60秒毎ping送信（変更不要）
- Produces: 挙動修正のみ（新しいメッセージ型は追加しない）

- [ ] **Step 1: `PeerListener.handleDisconnect`で`NWConnection`を明示的にcancelする**

`handleDisconnect(_ id:)`を次のように変える（現在は`connections[id] = nil`するだけで`cancel()`を呼んでいない。相手がFIN送信済みなのにこちら側がsocketを閉じないためCLOSE_WAITが残る）:

```swift
    private func handleDisconnect(_ id: PeerConnectionID) async {
        guard let connection = connections[id] else { return }
        connection.cancel()
        connections[id] = nil
        lineBuffers[id] = nil
        await onDisconnect(id)
    }
```

- [ ] **Step 2: `PeerClient`に受信監視watchdogを追加する**

プロパティ追加（`consecutiveWaitingCount`の近く）:

```swift
    /// 最後に何か（helloAck/ping/ack等）を受信した時刻。Macは接続中60秒毎にpingを送り続けるため、
    /// これが一定時間更新されなければ相手が死んでいる（daemon再起動等でTCPのFINが来ない/遅れる場合の
    /// 保険）と見なし再接続する（issue #7）
    private var lastActivityAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?
    private static let watchdogTimeoutSeconds: Double = 150
    private static let watchdogCheckIntervalSeconds: Double = 30
```

`handleConnectionState`の`.ready`ケースの先頭に`lastActivityAt = Date()`と`startWatchdog()`を追加:

```swift
        case .ready:
            consecutiveWaitingCount = 0
            lastActivityAt = Date()
            startWatchdog()
            state = .connected(description)
            backoffSeconds = 1
            send(.hello(hello))
            startReceiving()
            await resendPending()
```

`handleMessage(_:)`の先頭に`lastActivityAt = Date()`を追加（`switch message`の直前）。

`handleDisconnect(reason:)`の先頭（`guard let current = connection else { return }`の直後）に`watchdogTask?.cancel()`と`watchdogTask = nil`を追加。

`stop()`の中にも同様に`watchdogTask?.cancel()` / `watchdogTask = nil`を追加（`reconnectTask`の扱いと同じ並び）。

新規メソッドを`// MARK: - Receiving`の前あたりに追加:

```swift
    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogCheckIntervalSeconds))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.checkWatchdog()
            }
        }
    }

    private func checkWatchdog() {
        guard connection != nil else { return }
        guard Date().timeIntervalSince(lastActivityAt) > Self.watchdogTimeoutSeconds else { return }
        Diag.log("peer client: watchdog timeout, no activity for \(Self.watchdogTimeoutSeconds)s")
        handleDisconnect(reason: "watchdog timeout")
    }
```

- [ ] **Step 2.5: Self-review（実行はできないので読み合わせ）**
  - `connection.cancel()`は`NWConnection`のactor外呼び出しではなく`PeerListener`（actor）内から呼ぶので隔離違反にならないか確認
  - `watchdogTask`の`Task { [weak self] in ... }`が`PeerClient`（actor）のプロパティ・メソッドのみ触っており、captureされる`self`が`weak`なため`Task.detached`ではなく`Task { }`のままで良いか（既存の`reconnectTask`/`scheduleReconnect`と同じパターンに揃える）
  - `handleMessage`が`.ping`受信時に自分でも`lastActivityAt`を更新するため、Mac側の60秒毎pingが継続する限りwatchdogが誤発火しないこと（150秒 = 60秒の2.5倍のマージン）

- [ ] **Step 3: Run the gate** — このセッションではSwiftツールチェーンが無いため実行不可。Mac側セッションで`make verify`を実行し、結果を報告すること

- [ ] **Step 4: Commit**

```
git add Sources/notetaked/Peer/PeerListener.swift Apps/NotetakeMobile/PeerClient.swift
git commit -m "$(cat <<'EOF'
fix(peer): close stale sockets on disconnect and add client-side liveness watchdog

PeerListener dropped its connection reference without calling
NWConnection.cancel(), leaving the socket in CLOSE_WAIT after the peer
closed its side. PeerClient now also tracks the last time it received
anything from the peer's existing periodic ping and treats a long gap
the same as .failed, so a daemon restart that doesn't cleanly signal
the drop no longer leaves the iPhone app stuck showing "connected".

Unverified: this session has no Swift toolchain (Linux); reviewed by
reading only. Needs make verify + a real daemon-restart/network-drop
check in a Mac session.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

---

### Task 2: Reconcilerの話者継承（#8）と場所ラベル専用フィールド（#6）

**Files:**
- Modify: `Sources/NotetakeCore/Model/Utterance.swift`
- Modify: `Sources/NotetakeCore/Reconcile/Reconciler.swift`
- Modify: `Sources/NotetakeCore/Render/LocationLabel.swift`
- Modify: `Tests/NotetakeCoreTests/ReconcilerTests.swift`

**Interfaces:**
- Consumes: 既存の`Segment.levelDBFS` / `Segment.speaker?.global`（変更不要）
- Produces: `Utterance`に新規public fieldを5つ追加（`locationInput` / `locationPlatform` / `locationSource` / `locationDirection` / `locationLevelDBFS`）。既存の`input` / `platform` / `source` / `direction` / `speakerID`の意味・既存テストの期待値は変えない

- [ ] **Step 1: `Utterance`に場所ラベル専用フィールドを追加する（#6）**

`Utterance.swift`の`direction`フィールドの直後に追加:

```swift
    // 場所ラベル(LocationLabel)専用: 本文の勝者(input/platform/source/direction)とは別に、
    // 統合したsegのうちlevel_dbfsが最大のもの(話者に最も近いマイク)を追跡する（issue #6）
    public var locationInput: String
    public var locationPlatform: Platform
    public var locationSource: Source
    public var locationDirection: Direction?
    public var locationLevelDBFS: Double?
```

`CodingKeys`にも追加:

```swift
        case locationInput = "location_input"
        case locationPlatform = "location_platform"
        case locationSource = "location_source"
        case locationDirection = "location_direction"
        case locationLevelDBFS = "location_level_dbfs"
```

`Utterance`は`Reconciler.swift`と同じmodule（`NotetakeCore`）内でしか構築されないため、明示的な`public init`は無いまま（Swiftのmemberwise initはmodule内からは呼べる）。

- [ ] **Step 2: `Reconciler.makeUtterance`で初期値を設定し、話者継承ヘルパーを追加する（#6 + #8）**

`Config`に閾値を追加:

```swift
    public struct Config: Sendable {
        public var overlapRatio: Double = 0.5
        public var toleranceMS: Int64 = 1000
        public var textThreshold: Double = 0.5
        /// speakerが付かないsegについて、直前の同一device utteranceの話者を継承してよい最大の間隔（ms）（issue #8）
        public var speakerInheritanceGapMS: Int64 = 5_000
        public init() {}
    }
```

`makeUtterance(from:start:end:)`を次のように変える:

```swift
    private func makeUtterance(from seg: Segment, start: Int64, end: Int64) -> Utterance {
        var utterance = Utterance(
            id: seg.id,
            start: start,
            end: end,
            speakerID: seg.speaker?.global ?? inheritedSpeakerID(for: seg, start: start),
            speaker: "",
            text: seg.text,
            confidence: seg.confidence,
            source: seg.source,
            platform: seg.platform,
            ownerLabel: seg.owner,
            input: seg.input.name,
            sources: [seg.id],
            devices: [seg.device],
            direction: seg.direction,
            locationInput: seg.input.name,
            locationPlatform: seg.platform,
            locationSource: seg.source,
            locationDirection: seg.direction,
            locationLevelDBFS: seg.levelDBFS
        )
        utterance.speaker = label(speakerID: utterance.speakerID, ownerLabel: utterance.ownerLabel)
        return utterance
    }
```

新規private methodを`makeUtterance`の直後に追加:

```swift
    /// speakerが付かないsegについて、同じdeviceの直前のutteranceの話者を、時間差が
    /// `config.speakerInheritanceGapMS`以内なら継承する。継承元が無い（そのdeviceの
    /// 最初の発話）場合や閾値を超える場合はnilのまま（呼び出し側がownerLabelにfallbackする）（issue #8）
    private func inheritedSpeakerID(for seg: Segment, start: Int64) -> String? {
        for utterance in utterances.reversed() where utterance.devices.contains(seg.device) {
            guard start - utterance.end <= config.speakerInheritanceGapMS else { return nil }
            return utterance.speakerID
        }
        return nil
    }
```

- [ ] **Step 3: `merge`に場所ラベルの更新と話者継承を足す（#6 + #8）**

`merge(seg:into:start:end:)`の中、`direction`の更新ブロックの直前に場所ラベルの更新を追加し、末尾の話者付けブロックを継承対応に変える:

```swift
    private func merge(seg: Segment, into utterance: Utterance, start: Int64, end: Int64) -> Utterance {
        var merged = utterance
        merged.sources.append(seg.id)
        merged.devices.append(seg.device)
        merged.start = min(merged.start, start)
        merged.end = max(merged.end, end)

        if textWins(seg: seg, overCurrent: merged) {
            merged.text = seg.text
            merged.confidence = seg.confidence
            merged.source = seg.source
            merged.platform = seg.platform
            merged.ownerLabel = seg.owner
            merged.input = seg.input.name
        }

        if let level = seg.levelDBFS,
           merged.locationLevelDBFS.map({ level > $0 }) ?? true
        {
            merged.locationLevelDBFS = level
            merged.locationInput = seg.input.name
            merged.locationPlatform = seg.platform
            merged.locationSource = seg.source
            merged.locationDirection = seg.direction
        }

        if let candidate = seg.direction,
           merged.direction.map({ candidate.confidence > $0.confidence }) ?? true
        {
            merged.direction = candidate
        }

        if merged.speakerID == nil {
            merged.speakerID = seg.speaker?.global ?? inheritedSpeakerID(for: seg, start: start)
        }
        merged.speaker = label(speakerID: merged.speakerID, ownerLabel: merged.ownerLabel)
        return merged
    }
```

（`merged.speakerID == nil`の条件は既存のまま。以前は`seg.speaker?.global`だけを見ていたのを`?? inheritedSpeakerID(...)`で拡張した）

- [ ] **Step 4: `LocationLabel.text(for:)`を新フィールド参照に変える（#6）**

```swift
    public static func text(for utterance: Utterance) -> String {
        text(inputName: utterance.locationInput, platform: utterance.locationPlatform, source: utterance.locationSource,
             direction: utterance.locationDirection)
    }
```

（`text(inputName:platform:source:direction:)`自体は変更不要）

- [ ] **Step 5: テストを追加する**

`ReconcilerTests.swift`の`seg(...)`ヘルパーに`levelDBFS: Double? = nil`引数を追加し、`Segment(...)`呼び出しの`levelDBFS: nil`を`levelDBFS: levelDBFS`に変える。

話者継承（#8）のテストを追加:

```swift
@Test func speakerlessSegmentInheritsPriorSameDeviceSpeakerWithinGap() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", owner: "小芝", start: 0, end: 1000, text: "うん", global: "g2"))
    let out = r.apply(seg(device: "mac1", owner: "小芝", start: 1500, end: 2500, text: "連絡きたの"))
    #expect(out[0].speakerID == "g2")
}

@Test func speakerlessSegmentFallsBackToOwnerWhenGapExceedsThreshold() {
    var r = Reconciler()
    r.apply(seg(device: "mac1", owner: "小芝", start: 0, end: 1000, text: "うん", global: "g2"))
    let out = r.apply(seg(device: "mac1", owner: "小芝", start: 10_000, end: 11_000, text: "連絡きたの"))
    #expect(out[0].speakerID == nil)
    #expect(out[0].speaker == "小芝")
}
```

場所ラベル（#6）のテストを追加:

```swift
@Test func locationLabelFollowsHighestLevelSegNotTextWinner() {
    var r = Reconciler()
    r.apply(seg(device: "ip", platform: .ios, start: 0, end: 1000, text: "こんにちは", confidence: 0.9, levelDBFS: -30))
    let out = r.apply(seg(device: "mac", start: 100, end: 1100, text: "こんにちは。", confidence: 0.95, levelDBFS: -10))
    // 本文はconfidenceの高いmac側（現状のtextWins仕様のまま）
    #expect(out[0].text == "こんにちは。")
    #expect(out[0].platform == .mac)
    // 場所ラベルはlevel_dbfsが高い(=話者に近い)ip側
    #expect(out[0].locationPlatform == .ios)
    #expect(LocationLabel.text(for: out[0]) == "iPhone")
}
```

- [ ] **Step 5.5: Self-review（実行はできないので読み合わせ）**
  - `inheritedSpeakerID`が`utterances.reversed()`で最初に一致する（同じ`device`を含む）ものだけを見て、それより古いutteranceへ遡らないこと（`return`で打ち切っているか）
  - `Utterance`の新規fieldが`Equatable`合成・`Codable`合成の対象になり、他の`Utterance(...)`呼び出し（`ReconcilerTests.swift`以外、`TranscriptRendererTests.swift`等）でコンパイルエラーにならないか（`grep -rn "Utterance("`で全呼び出し元を確認する）
  - `merge`内の場所ラベル更新順序が`textWins`のブロックと独立している（本文の勝者判定に影響しない）こと

- [ ] **Step 6: Run the gate** — このセッションではSwiftツールチェーンが無いため実行不可。Mac側セッションで`make verify`を実行し、結果を報告すること

- [ ] **Step 7: Commit**

```
git add Sources/NotetakeCore/Model/Utterance.swift Sources/NotetakeCore/Reconcile/Reconciler.swift Sources/NotetakeCore/Render/LocationLabel.swift Tests/NotetakeCoreTests/ReconcilerTests.swift
git commit -m "$(cat <<'EOF'
fix(reconcile): inherit speaker for gap-filling segments, label location by loudest device

Segments the Aligner couldn't attach a speaker to (issue #8) fell back
to the owner label even when the same device's immediately preceding
utterance already had a resolved speaker, splitting one person across
an owner-name row and a speaker-id row. They now inherit that prior
utterance's speakerID when the gap is within 5s.

Utterance gained a separate location* (input/platform/source/direction/
level_dbfs) winner tracked independently from the text winner, chosen
by whichever merged segment has the highest level_dbfs (closest mic to
the speaker). LocationLabel.text(for:) now reads from it instead of
the text-winner fields, per the user's 2026-09-14 decision on issue #6.

Unverified: this session has no Swift toolchain (Linux); reviewed by
reading only. Needs make verify.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

---

### Task 3: ライブパネルのボタン配置とMac/iPhoneの用語整理（#3 + #5）

**Files:**
- Modify: `Apps/Notetake/LivePanelView.swift`
- Modify: `Apps/NotetakeMobile/ContentView.swift`

**Interfaces:**
- Consumes: 既存の`AppModel` / `MobileModel`のpublic API（変更不要。文言・レイアウトのみ）
- Produces: 挙動修正なし。表示文言とレイアウトのみ

- [ ] **Step 1: `LivePanelView`の操作ボタンをtoolbarから本文へ移す（#3）**

`.toolbar { ... }`ブロックを、ステータス文言だけ残す形に変える:

```swift
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
        }
```

`ScrollViewReader { ... }`の直前（`var body: some View { `の直後）に、ボタン行を追加する。幅が狭い時はtoolbar overflow（`>>`）ではなく横スクロールへ逃がす（issue本文の案2）:

```swift
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("セッション開始") { appModel.startRecording() }
                        .disabled(appModel.outputDirectory == nil || appModel.isRecording)
                    Button("セッション終了") { appModel.stopRecording() }
                        .disabled(!appModel.isRecording)
                    Button("区切る") { appModel.rotateRecording() }
                        .disabled(!appModel.isRecording)
                    Button("整形") { appModel.polishLastRecording() }
                        .disabled(appModel.lastFinishedPrefix == nil || appModel.isPolishing)
                    Toggle("常に前面", isOn: $floating)
                        .onChange(of: floating) { applyFloating(floating) }
                    Button("全文コピー") { appModel.copyAllToPasteboard() }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            Divider()
            ScrollViewReader { proxy in
                // 既存のScrollView { ... } をそのままここへ
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
        }
    }
```

既存の`ScrollViewReader { ... }`ブロック（`.textSelection(.enabled)`や`.onChange`を含む）はそのまま`VStack`の2番目の子として残す。`.frame(minWidth:minHeight:)`と新しい`.toolbar`はこの`VStack`に付け替える（現在`ScrollViewReader`直後に付いているものを外へ出す）。

- [ ] **Step 2: `statusText`の文言を「セッション」に揃える（#5、Mac側）**

```swift
    private var statusText: String {
        guard appModel.isRecording else { return "セッション無し" }
        var text = "セッション中 \(appModel.prefix ?? "")"
        ...（以下、既存の`if`ブロックはそのまま）
    }
```

（`"収録中 \(...)"` → `"セッション中 \(...)"`、`"停止中"` → `"セッション無し"`のみ変更。ソースの追記行・次の区切り・入力・接続の各行はそのまま）

- [ ] **Step 3: iPhone `ContentView`のボタン・セクション文言を「取り込み」に揃える（#5、iPhone側）**

```swift
                Section("取り込み") {
                    Button(model.isRecording ? "取り込み中（タップで終了）" : "取り込み開始") {
                        if model.isRecording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    }
                    Text("Macでセッションを開始してから使ってください。取り込んだ音声は時刻でMacのセッションに自動的に統合されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !model.lastText.isEmpty {
                        Text(model.lastText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
```

- [ ] **Step 3.5: Self-review（実行はできないので読み合わせ）**
  - `LivePanelView`の`VStack`への付け替えで`ScrollViewReader`内の`proxy.scrollTo(...)`呼び出しが引き続き機能する構造になっているか（`ScrollViewReader`自体は移動しないので影響なし）
  - ボタンの`.disabled`条件が元のまま1文字も変わっていないこと（文言以外は変えない）
  - `ContentView.swift`のButtonラベルが`isRecording`の値で分岐する既存パターンを保っていること

- [ ] **Step 4: Run the gate** — このセッションではSwiftツールチェーンが無いため実行不可。Mac側セッションで`make app`（mac）と`make verify`のiOSビルドで確認し、`make app`後に実際にwindowを狭めてボタン行が横スクロールすることを確認すること

- [ ] **Step 5: Commit**

```
git add Apps/Notetake/LivePanelView.swift Apps/NotetakeMobile/ContentView.swift
git commit -m "$(cat <<'EOF'
fix(ui): move live panel buttons out of the toolbar overflow, clarify session vs. capture wording

The record/stop/rotate/polish/float/copy-all buttons lived in
LivePanelView's .toolbar, so a narrow window folded them behind
macOS's toolbar overflow chevron with an awkward reopen position
(issue #3). They now sit in a horizontally scrollable row in the body,
leaving only the status text in the toolbar.

Both apps used "開始"/"収録" for two different things: the Mac button
starts the daemon's session (the timed.jsonl the iPhone's audio later
joins by timestamp), the iPhone button only starts local capture
(issue #5). Renamed the Mac panel's buttons/status to "セッション"
wording and the iPhone section/button to "取り込み" wording, with a
short note that capture joins whatever Mac session is already running.

Unverified: this session has no Swift toolchain (Linux); reviewed by
reading only. Needs make verify + a look at the panel at a narrow
window width in a Mac session.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Lmk1k5w2dKW8DQkkZRq2VL
EOF
)"
```

---

## 完了後にHANDOFF.mdへ書くこと

- Task 1〜3が「実装済み・未検証」であること（このセッションはLinuxでSwiftツールチェーンが無い）
- 各issueで対応した範囲・対応しなかった範囲:
  - #7: `PeerListener`のCLOSE_WAIT修正とclient側watchdog（150秒無通信で再接続）。issue本文が提案するclient発pingではなくMacの既存pingの受信監視で代替したこと
  - #8: 直前の同一device utteranceからの話者継承（5秒以内）。継承元が無い最初の発話や5秒を超える間隔はownerLabelのまま
  - #6: `Utterance`の`location*`フィールドと`LocationLabel`の参照先変更。本文の勝者判定（`text`/`input`/`platform`/`source`/`direction`）は無変更
  - #3: toolbar overflowを本文の横スクロール行へ変更
  - #5: Mac/iPhoneのボタン・状態文言を「セッション」「取り込み」に整理。Macの現在prefixをiPhoneへ伝えるプロトコル変更はスコープ外のままissueに残す
- #4はコード変更なし。`docs/superpowers/specs/2026-09-16-icloud-pairing-design.md`に検討結果を記載し、issueに実装は含まれないことを明記する
- 次にMac側セッションでやること: `make verify` → 実機確認（#7: daemon再起動後にiPhone appが自動で再接続すること、#8: 2話者の短い相槌が分裂しないこと、#6: 2デバイス同時収録で場所ラベルが音量の大きい方になること、#3: window幅を狭めてボタン行が横スクロールで使えること、#5: 文言が意図通り出ること）
