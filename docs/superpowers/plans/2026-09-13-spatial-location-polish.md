# 場所情報（入力機材・方位）と整形の対話化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 各segに「どの入力機材で拾ったか」（`input`）と、空間収録対応機材では「どの方位から」（`direction`）を残し、final.md / ライブパネルに短く表示する。整形（polish）は時刻を捨てて対話turnだけを整える。

**Architecture:** NotetakeCoreに純粋な型・計算（`InputDevice` / `Direction` / `LocationLabel` / `DirectionEstimator`）とモデル拡張（`Segment` / `Utterance` / `Reconciler` / renderer / polish）を足す。Mac daemonは開始時に既定入力機材を`AVCaptureDevice`で判定してsegに刻む（FOA経路は作らない）。iPhone appは取り込みを`AVCaptureSession`に置き換え、FOA対応ならW chをTranscriberへ、4chを`DirectionEstimator`へ流してsegに`direction`を付ける。

**Tech Stack:** Swift 6（strict concurrency）、swift-testing（`@Test` / `#expect`）、AVFoundation（`AVCaptureSession` / `AVCaptureAudioDataOutput.spatialAudioChannelLayoutTag`）、Foundation Models、SwiftUI。

**Spec:** `docs/superpowers/specs/2026-09-13-spatial-location-polish-design.md`（親: `docs/superpowers/specs/2026-09-12-notetake-design.md`）

## Global Constraints

- 過去互換は不要（既存の`timed.jsonl`が読めなくなってよい）
- JSONキーはsnake_case（`azimuth_deg` / `input_name` / `input_spatial`）
- `direction`は`input.spatial == true`のsegにのみ付き、無い時はキー自体を出さない（`Optional`をencodeしない）
- 方位角: 0以上360未満、機材の上端方向を0°、上から見て時計回り
- 方位の表示は時計位置（`12時`〜`11時`）、機材の短縮ラベルは `Mac` / `AirPods` / `iPhone` / `Watch` / `system`
- 整形出力は時刻無し。見出し `# yyyy-MM-dd 参加者` + `**話者**: 本文` 行のみ
- Mac側にFOA取り込み経路は作らない（対応機材が無い）
- テストが仕様。既存テストの期待値を変えるのは本planで明示した箇所のみ
- 各taskの末尾で `swift build 2>&1 | grep -i warning` が空であること（warningゼロを維持）
- commit messageの末尾にCo-Authored-By / Claude-Session trailer（CLAUDE.md）
- モデル分担: コード記述 = Sonnet subagent、build / test / xcodebuild = Haiku subagent、review = Sonnet

## 検証コマンド

```bash
swift build 2>&1 | grep -E "error|warning"          # Core + daemon（出力なしが正常）
swift test 2>&1 | tail -5                            # Coreのテスト
swift test --filter <TestName> 2>&1 | tail -20       # 単体
make app 2>&1 | grep -E "error:|BUILD"               # Mac app（BUILD SUCCEEDED）
# iOS app（署名なしでコンパイルだけ通す。Watch targetも依存として一緒に通る）
xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
```

`make app`と`xcodebuild`はBash sandboxではpackage解決のネットワークが止まるため、sandbox無効で実行する（HANDOFF.md「環境の注意」）。

## File Structure

| ファイル | 責務 |
|---|---|
| `Sources/NotetakeCore/Model/Location.swift`（新規） | `InputDevice` / `Direction` の型 |
| `Sources/NotetakeCore/Model/Segment.swift` | `input` / `direction` フィールド |
| `Sources/NotetakeCore/Model/Utterance.swift` | `platform` / `input` / `direction` フィールド |
| `Sources/NotetakeCore/Reconcile/Reconciler.swift` | 統合時の `input` / `platform` / `direction` の採用規則 |
| `Sources/NotetakeCore/Render/LocationLabel.swift`（新規） | 短縮ラベル・時計位置・表示文字列（純粋関数） |
| `Sources/NotetakeCore/Render/TranscriptRenderer.swift` | 話者行に場所を付ける |
| `Sources/NotetakeCore/Control/Messages.swift` | `StatusEvent.inputName` / `inputSpatial` |
| `Sources/NotetakeCore/Audio/DirectionEstimator.swift`（新規） | FOAフレーム→方位・信頼度、seg範囲の円平均 |
| `Sources/NotetakeCore/Polish/PolishChunker.swift` / `PolishRenderer.swift` | 時刻無しturn、見出し付き対話出力 |
| `Sources/notetaked/Audio/InputDeviceProbe.swift`（新規） | 既定入力機材の名前・uid・FOA対応判定 |
| `Sources/notetaked/Pipeline/ServeSession.swift` | streamごとの `input` をsegへ、statusへ |
| `Sources/notetaked/Polish/Polisher.swift` / `Commands/PolishCommand.swift` | instructions、見出し用の収録日 |
| `Apps/Notetake/AppModel.swift` / `LivePanelView.swift` | 状態行と行の場所表示 |
| `Apps/NotetakeMobile/Recorder.swift` | `AVCaptureSession` + FOA + 方位 |
| `Apps/NotetakeMobile/MobileModel.swift` / `WatchRelay.swift` | segへ `input` / `direction` |
| `Tests/NotetakeCoreTests/*` | 各純粋ロジックのテスト |
| `HANDOFF.md` | 検証手順の追記 |

---

### Task 1: `InputDevice` / `Direction` 型と Segment / Utterance / Reconciler の拡張

**Files:**
- Create: `Sources/NotetakeCore/Model/Location.swift`
- Modify: `Sources/NotetakeCore/Model/Segment.swift`（プロパティ・CodingKeys・init）
- Modify: `Sources/NotetakeCore/Model/Utterance.swift`
- Modify: `Sources/NotetakeCore/Reconcile/Reconciler.swift:100-134`（`makeUtterance` / `merge`）
- Create: `Sources/notetaked/Audio/InputDeviceProbe.swift`
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift`（`RunningStream`、`startCapture`、`handle(streamEvent:)`、`handleFinal`）
- Modify: `Apps/NotetakeMobile/MobileModel.swift:186`、`Apps/NotetakeMobile/WatchRelay.swift:240`
- Create: `Tests/NotetakeCoreTests/TestInputDevice.swift`
- Modify: `Tests/NotetakeCoreTests/NDJSONTests.swift`、`ReconcilerTests.swift`、`OutboxTests.swift`、`PeerMessageTests.swift`、`SessionStoreTests.swift`、`TranscriptRendererTests.swift`、`PolishChunkerTests.swift`（コンストラクタ引数の追加のみ）

**Interfaces:**
- Produces:
  - `public struct InputDevice: Codable, Sendable, Equatable { var name: String; var uid: String; var spatial: Bool; static let system: InputDevice }`
  - `public struct Direction: Codable, Sendable, Equatable { var azimuthDeg: Double /* key azimuth_deg */; var confidence: Double }`
  - `Segment.input: InputDevice`（init引数、`source:`の直後、既定値なし）、`Segment.direction: Direction?`（init引数、`speaker:`の直後、既定nil）
  - `Utterance.platform: Platform`、`Utterance.input: String`、`Utterance.direction: Direction?`（memberwise initの引数順は `source` の直後に `platform`、`ownerLabel` の直後に `input`、末尾に `direction`）
  - `enum InputDeviceProbe { static func current() -> InputDevice }`（notetaked）
  - test helper: `extension InputDevice { static let test: InputDevice }`

- [x] **Step 1: 型を追加する**

`Sources/NotetakeCore/Model/Location.swift`:

```swift
import Foundation

/// 音を拾った入力機材。Macでは内蔵マイクかAirPodsか等が収録ごとに変わる
public struct InputDevice: Codable, Sendable, Equatable {
    public var name: String      // AVCaptureDevice.localizedName
    public var uid: String       // AVCaptureDevice.uniqueID
    public var spatial: Bool     // 開始時の isMultichannelAudioModeSupported(.firstOrderAmbisonics)

    public init(name: String, uid: String, spatial: Bool) {
        self.name = name
        self.uid = uid
        self.spatial = spatial
    }

    /// Macのシステム音声tap
    public static let system = InputDevice(name: "system", uid: "system", spatial: false)
}

/// 空間収録対応機材でのみ付く方位。機材の上端方向を0°、上から見て時計回り
public struct Direction: Codable, Sendable, Equatable {
    public var azimuthDeg: Double   // key: azimuth_deg、0 <= x < 360
    public var confidence: Double   // 0...1

    enum CodingKeys: String, CodingKey {
        case azimuthDeg = "azimuth_deg"
        case confidence
    }

    public init(azimuthDeg: Double, confidence: Double) {
        self.azimuthDeg = azimuthDeg
        self.confidence = confidence
    }
}
```

- [x] **Step 2: 失敗するテストを書く**

`Tests/NotetakeCoreTests/TestInputDevice.swift`:

```swift
@testable import NotetakeCore

extension InputDevice {
    static let test = InputDevice(name: "MacBook Airのマイク", uid: "BuiltInMicrophoneDevice", spatial: false)
}
```

`Tests/NotetakeCoreTests/NDJSONTests.swift` に追加:

```swift
@Test func segmentEncodesInputAndDirection() throws {
    let segment = Segment(
        id: UUID(), session: "s1", seq: 1, device: "iphone-1", deviceName: "bash iPhone",
        owner: "bash", platform: .ios, source: .mic,
        input: InputDevice(name: "iPhone マイク", uid: "mic-1", spatial: true),
        start: 1_000, end: 2_000, text: "こんにちは",
        direction: Direction(azimuthDeg: 57.3, confidence: 0.82)
    )
    let line = try NDJSON.encode(.segment(segment))
    #expect(line.contains("\"input\":{"))
    #expect(line.contains("\"spatial\":true"))
    #expect(line.contains("\"azimuth_deg\":57.3"))
    let decoded = try NDJSON.decode(line)
    #expect(decoded == .segment(segment))
}

@Test func segmentWithoutDirectionOmitsKey() throws {
    let segment = Segment(
        id: UUID(), session: "s1", seq: 1, device: "mac-1", deviceName: "Mac",
        owner: "bash", platform: .mac, source: .mic, input: .test,
        start: 1_000, end: 2_000, text: "こんにちは"
    )
    let line = try NDJSON.encode(.segment(segment))
    #expect(!line.contains("direction"))
    #expect(line.contains("\"input\":{"))
}
```

`NDJSON.decode(_:)`の実名は`Sources/NotetakeCore/Codec/NDJSON.swift`で確認して合わせる（`decodeAll`の単数版が無ければ`decodeAll(line).first`で比較する）。

`Tests/NotetakeCoreTests/ReconcilerTests.swift` に追加（既存の`seg(...)`helperに `input: InputDevice = .test, direction: Direction? = nil` 引数を足してSegmentへ渡す）:

```swift
@Test func utteranceCarriesInputPlatformAndDirectionOfSegment() {
    var r = Reconciler()
    let d = Direction(azimuthDeg: 90, confidence: 0.9)
    let out = r.apply(seg(device: "ip", platform: .ios, start: 0, end: 1000, text: "こんにちは",
                          input: InputDevice(name: "iPhone マイク", uid: "m", spatial: true), direction: d))
    #expect(out[0].input == "iPhone マイク")
    #expect(out[0].platform == .ios)
    #expect(out[0].direction == d)
}

@Test func mergeKeepsDirectionFromSpatialSegmentEvenWhenTextComesFromOther() {
    var r = Reconciler()
    let d = Direction(azimuthDeg: 90, confidence: 0.9)
    r.apply(seg(device: "ip", platform: .ios, start: 0, end: 1000, text: "こんにちは", confidence: 0.5,
                input: InputDevice(name: "iPhone マイク", uid: "m", spatial: true), direction: d))
    let out = r.apply(seg(device: "mac", start: 100, end: 1100, text: "こんにちは。", confidence: 0.9))
    #expect(out[0].text == "こんにちは。")
    #expect(out[0].input == "MacBook Airのマイク")
    #expect(out[0].platform == .mac)
    #expect(out[0].direction == d)
}

@Test func mergePrefersHigherConfidenceDirection() {
    var r = Reconciler()
    let weak = Direction(azimuthDeg: 10, confidence: 0.3)
    let strong = Direction(azimuthDeg: 200, confidence: 0.8)
    r.apply(seg(device: "a", platform: .ios, start: 0, end: 1000, text: "こんにちは",
                input: InputDevice(name: "a", uid: "a", spatial: true), direction: weak))
    let out = r.apply(seg(device: "b", platform: .ios, start: 0, end: 1000, text: "こんにちは",
                          input: InputDevice(name: "b", uid: "b", spatial: true), direction: strong))
    #expect(out[0].direction == strong)
}
```

- [x] **Step 3: テストが失敗（コンパイルエラー）することを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter segmentEncodesInputAndDirection 2>&1 | tail -20`
Expected: `error: extra argument 'input' in call` 等のコンパイルエラー

- [x] **Step 4: Segment / Utterance / Reconciler を実装する**

`Segment.swift`: プロパティ `public var input: InputDevice`（`source`の次）と `public var direction: Direction?`（`speaker`の次）、CodingKeys に `case input` / `case direction`、init引数 `input: InputDevice`（`source:`の直後、既定値なし）と `direction: Direction? = nil`（`speaker:`の直後）。

`Utterance.swift`: `public var platform: Platform`（`source`の次）、`public var input: String`（`ownerLabel`の次、採用本文segの`input.name`）、`public var direction: Direction?`（末尾）。CodingKeys に `case platform` / `case input` / `case direction`。

`Reconciler.swift`:
- `makeUtterance`: `platform: seg.platform, input: seg.input.name, direction: seg.direction` を渡す
- `merge`: `textWins`が真の分岐で `merged.platform = seg.platform` と `merged.input = seg.input.name` も更新。その後、`textWins`と独立に:

```swift
if let candidate = seg.direction,
   merged.direction.map({ candidate.confidence > $0.confidence }) ?? true
{
    merged.direction = candidate
}
```

- [x] **Step 5: daemon / app の生成箇所を直す**

`Sources/notetaked/Audio/InputDeviceProbe.swift`:

```swift
import AVFoundation
import NotetakeCore

/// 収録開始時に既定の音声入力機材を調べる。FOA対応判定は許可なしで即時に返る
enum InputDeviceProbe {
    static func current() -> InputDevice {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return InputDevice(name: "unknown", uid: "unknown", spatial: false)
        }
        let spatial = (try? AVCaptureDeviceInput(device: device))?
            .isMultichannelAudioModeSupported(.firstOrderAmbisonics) ?? false
        return InputDevice(name: device.localizedName, uid: device.uniqueID, spatial: spatial)
    }
}
```

`ServeSession.swift`:
- `RunningStream` に `let input: InputDevice` を追加
- `startCapture` の `for (source, ownerFor) in sourceOption.sources` 内で `let input: InputDevice = source == .system ? .system : InputDeviceProbe.current()` を求め、consumer Taskのclosureで `await self?.handle(streamEvent: event, source: source, owner: streamOwner, input: input)` と渡し、`RunningStream(source:owner:input:stream:consumer:)` に入れる
- `handle(streamEvent:source:owner:)` に `input: InputDevice` 引数を追加し `handleFinal(..., input: input)` へ
- `handleFinal` の `Segment(...)` に `input: input,` を `source: source,` の直後に追加

`Apps/NotetakeMobile/MobileModel.swift:186` の `Segment(...)` に `input: InputDevice(name: "iPhone", uid: settings.deviceID, spatial: false),`（Task 7でRecorderの判定結果に置き換える）。
`Apps/NotetakeMobile/WatchRelay.swift:240` の `Segment(...)` に `input: InputDevice(name: "Apple Watch", uid: meta.device, spatial: false),`。

- [x] **Step 6: 既存テストのコンストラクタを直す**

`Segment(` を呼ぶテスト（NDJSONTests / OutboxTests / PeerMessageTests / ReconcilerTests / SessionStoreTests）は `source: ...,` の直後に `input: .test,` を足す。`Utterance(` を呼ぶhelper（TranscriptRendererTests / PolishChunkerTests）は `source: source,` の直後に `platform: .mac,`、`ownerLabel: ...,` の直後に `input: "MacBook Airのマイク",` を足す（helperの引数に `platform: Platform = .mac` / `input: String = "MacBook Airのマイク"` / `direction: Direction? = nil` を追加して渡す）。

- [x] **Step 7: 全テストとビルドが通ることを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test 2>&1 | tail -5` → 全件PASS（既存 + 新規5件）
Run: `swift build 2>&1 | grep -E "error|warning"` → 出力なし
Run: iOS app のコンパイル（検証コマンド参照）→ `BUILD SUCCEEDED`。このbranchのiOS appは未コンパイルなので、本taskで触っていないファイルのエラーが出た場合はエラー行をそのまま報告し、修正はtouchしたファイルに限る

- [x] **Step 8: Commit**（commit c500029）

```bash
git add Sources Apps Tests
git commit -m "feat(core): record input device and direction on segments and utterances"
```

---

### Task 2: `LocationLabel`（短縮ラベル・時計位置・表示文字列）

**Files:**
- Create: `Sources/NotetakeCore/Render/LocationLabel.swift`
- Create: `Tests/NotetakeCoreTests/LocationLabelTests.swift`

**Interfaces:**
- Produces:
  - `LocationLabel.short(inputName: String, platform: Platform, source: Source) -> String`
  - `LocationLabel.clock(azimuthDeg: Double) -> String`（`"12時"`〜`"11時"`）
  - `LocationLabel.text(inputName: String, platform: Platform, source: Source, direction: Direction?) -> String`（`"iPhone 2時"` / `"Mac"`）
  - `LocationLabel.text(for utterance: Utterance) -> String`

- [x] **Step 1: 失敗するテストを書く**

```swift
import Testing
@testable import NotetakeCore

@Test func shortLabelTable() {
    #expect(LocationLabel.short(inputName: "system", platform: .mac, source: .system) == "system")
    #expect(LocationLabel.short(inputName: "Apple Watch", platform: .watchos, source: .watch) == "Watch")
    #expect(LocationLabel.short(inputName: "iPhone マイク", platform: .ios, source: .mic) == "iPhone")
    #expect(LocationLabel.short(inputName: "ゆふAirPods Pro 3", platform: .mac, source: .mic) == "AirPods")
    #expect(LocationLabel.short(inputName: "MacBook Airのマイク", platform: .mac, source: .mic) == "Mac")
}

@Test func clockPositionRoundsToNearestHour() {
    #expect(LocationLabel.clock(azimuthDeg: 0) == "12時")
    #expect(LocationLabel.clock(azimuthDeg: 14) == "12時")
    #expect(LocationLabel.clock(azimuthDeg: 16) == "1時")
    #expect(LocationLabel.clock(azimuthDeg: 57.3) == "2時")
    #expect(LocationLabel.clock(azimuthDeg: 270) == "9時")
    #expect(LocationLabel.clock(azimuthDeg: 345) == "12時")
    #expect(LocationLabel.clock(azimuthDeg: 359.9) == "12時")
}

@Test func textCombinesLabelAndClock() {
    let d = Direction(azimuthDeg: 57.3, confidence: 0.8)
    #expect(LocationLabel.text(inputName: "iPhone マイク", platform: .ios, source: .mic, direction: d) == "iPhone 2時")
    #expect(LocationLabel.text(inputName: "MacBook Airのマイク", platform: .mac, source: .mic, direction: nil) == "Mac")
}
```

- [x] **Step 2: 失敗を確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter shortLabelTable 2>&1 | tail -5` → コンパイルエラー（`LocationLabel` 未定義）

- [x] **Step 3: 実装する**

```swift
import Foundation

/// 場所（入力機材・方位）の表示用文字列。パネルとfinal.mdで共通
public enum LocationLabel {
    public static func short(inputName: String, platform: Platform, source: Source) -> String {
        if source == .system { return "system" }
        switch platform {
        case .watchos: return "Watch"
        case .ios: return "iPhone"
        case .mac: return inputName.contains("AirPods") ? "AirPods" : "Mac"
        }
    }

    /// 30°刻みで最寄りの時計位置。0°→12時
    public static func clock(azimuthDeg: Double) -> String {
        let hour = Int((azimuthDeg / 30).rounded()) % 12
        return "\(hour == 0 ? 12 : hour)時"
    }

    public static func text(inputName: String, platform: Platform, source: Source, direction: Direction?) -> String {
        let label = short(inputName: inputName, platform: platform, source: source)
        guard let direction else { return label }
        return "\(label) \(clock(azimuthDeg: direction.azimuthDeg))"
    }

    public static func text(for utterance: Utterance) -> String {
        text(inputName: utterance.input, platform: utterance.platform, source: utterance.source,
             direction: utterance.direction)
    }
}
```

- [x] **Step 4: 通ることを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter LocationLabel 2>&1 | tail -5` → PASS。`swift build 2>&1 | grep -i warning` → 出力なし

- [x] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Render/LocationLabel.swift Tests/NotetakeCoreTests/LocationLabelTests.swift
git commit -m "feat(core): LocationLabel for input device and clock-position display"
```

---

### Task 3: final.md の話者行に場所を付ける

**Files:**
- Modify: `Sources/NotetakeCore/Render/TranscriptRenderer.swift`
- Modify: `Tests/NotetakeCoreTests/TranscriptRendererTests.swift`

**Interfaces:**
- Consumes: `LocationLabel.text(for:)`（Task 2）
- Produces: 行書式 `HH:mm:ss **話者**（場所）: 本文`

- [x] **Step 1: 既存テストの期待値を新書式へ変え、場所付きのテストを足す**

既存テストの期待文字列中の `**話者**: ` を `**話者**（Mac）: ` に変える（helperの既定 `input: "MacBook Airのマイク"`, `platform: .mac`, `source: .mic` は `Mac` になる）。追加:

```swift
@Test func rendersDirectionAsClockPosition() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let u = utterance(start: 0, speaker: "田中", text: "はい", source: .mic,
                      platform: .ios, input: "iPhone マイク",
                      direction: Direction(azimuthDeg: 90, confidence: 0.9))
    let line = TranscriptRenderer.markdown([u], timeZone: tokyo)
    #expect(line.hasSuffix("**田中**（iPhone 3時）: はい\n"))
}
```

- [x] **Step 2: 失敗を確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter TranscriptRenderer 2>&1 | tail -10` → 期待値不一致でFAIL

- [x] **Step 3: 実装する**

`TranscriptRenderer.markdown` のループ内:

```swift
let location = LocationLabel.text(for: utterance)
result += "\(time) **\(utterance.speaker)**（\(location)）: \(text)\n"
```

doc commentの書式も `"HH:mm:ss **話者**（場所）: 本文\n"` に更新。

- [x] **Step 4: 通ることを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test 2>&1 | tail -5` → 全件PASS

- [x] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Render/TranscriptRenderer.swift Tests/NotetakeCoreTests/TranscriptRendererTests.swift
git commit -m "feat(core): show input device and direction in final.md speaker lines"
```

---

### Task 4: `StatusEvent` に入力機材を載せる

**Files:**
- Modify: `Sources/NotetakeCore/Control/Messages.swift:80-99`
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift`（`startCapture` / `start` / `rotate` / `stop`）
- Modify: `Tests/NotetakeCoreTests/MessagesTests.swift`

**Interfaces:**
- Produces: `StatusEvent.inputName: String?`（key `input_name`）、`StatusEvent.inputSpatial: Bool?`（key `input_spatial`）。init引数は `sources:` の直後に `inputName: String? = nil, inputSpatial: Bool? = nil`
- ServeSession: `private var currentInput: InputDevice?`（mic streamの`input`。mic無しならnil。停止でnil）

- [x] **Step 1: 失敗するテストを書く**

`MessagesTests.swift` に追加（既存のEvent round-tripテストの書き方に合わせる。`Event`のencode/decode関数名はファイル内の既存テストから取る）:

```swift
@Test func statusEventCarriesInputDevice() throws {
    let status = StatusEvent(recording: true, prefix: "2026-09-13T10-00-00", sources: [.mic],
                             inputName: "MacBook Airのマイク", inputSpatial: false, outputDirectory: "/tmp")
    let line = try NDJSON.encode(Event.status(status))
    #expect(line.contains("\"input_name\":\"MacBook Airのマイク\""))
    #expect(line.contains("\"input_spatial\":false"))
}

@Test func statusEventWithoutInputOmitsKeys() throws {
    let status = StatusEvent(recording: false, sources: [], outputDirectory: "/tmp")
    let line = try NDJSON.encode(Event.status(status))
    #expect(!line.contains("input_name"))
}
```

- [x] **Step 2: 失敗を確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter statusEventCarriesInputDevice 2>&1 | tail -5` → コンパイルエラー

- [x] **Step 3: 実装する**

`StatusEvent` にプロパティ `public var inputName: String?` / `public var inputSpatial: Bool?`、CodingKeys `case inputName = "input_name"` / `case inputSpatial = "input_spatial"`、init引数（既定nil）。

`ServeSession`:
- `private var currentInput: InputDevice?` を追加
- `startCapture` 成功時（`self.streams = started` の直後）に `self.currentInput = started.first(where: { $0.source == .mic })?.input`
- `stopCapture` の末尾（`self.store = nil` の隣）で `currentInput = nil`
- `start()` / `rotate()` の `StatusEvent(recording: true, ...)` に `inputName: currentInput?.name, inputSpatial: currentInput?.spatial` を渡す（`stop()`の`recording: false`は既定nilのまま）

- [x] **Step 4: 通ることを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test 2>&1 | tail -5` → PASS。`swift build 2>&1 | grep -E "error|warning"` → 出力なし

- [x] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Control/Messages.swift Sources/notetaked/Pipeline/ServeSession.swift Tests/NotetakeCoreTests/MessagesTests.swift
git commit -m "feat(daemon): report current input device in status events"
```

---

### Task 5: ライブパネルの場所表示

**Files:**
- Modify: `Apps/Notetake/AppModel.swift`（プロパティと`.status`処理）
- Modify: `Apps/Notetake/LivePanelView.swift`（`statusText`、`UtteranceRow`）

**Interfaces:**
- Consumes: `StatusEvent.inputName` / `inputSpatial`（Task 4）、`LocationLabel.text(for:)`（Task 2）、`Utterance.direction`（Task 1）
- Produces: `AppModel.inputName: String?`、`AppModel.inputSpatial: Bool?`

- [x] **Step 1: AppModel を直す**

`var sources: [Source] = []` の隣に:

```swift
/// 現在の収録の入力機材（daemonの`status.input_name`）。停止中はnil
var inputName: String?
var inputSpatial: Bool?
```

`handle(_:)` の `case .status(let status)` で `sources = status.sources` の直後に:

```swift
inputName = status.inputName
inputSpatial = status.inputSpatial
```

- [x] **Step 2: LivePanelView を直す**

`statusText` の `接続:` の前に:

```swift
if let inputName = appModel.inputName {
    text += " 入力: \(inputName)（空間: \(appModel.inputSpatial == true ? "対応" : "非対応")）"
}
```

`UtteranceRow.body` で話者名（Button / Text）の直後、`Text(utterance.text)` の前に:

```swift
Text(LocationLabel.text(for: utterance))
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [x] **Step 3: ビルドして起動する**（2026-09-13 `make verify`で確認）

Run: `make app 2>&1 | grep -E "error:|BUILD"` → `BUILD SUCCEEDED`
Run: 既存のNotetake.appを終了（`pkill -f "Notetake.app/Contents/MacOS/Notetake"`）してから `open .build/DerivedData/Build/Products/Debug/Notetake.app`。パネルで収録開始し、状態行に `入力: MacBook Airのマイク（空間: 非対応）`、発話行に `Mac` が出ることを確認（画面確認はuser）。保存先の`timed.jsonl`に `"input":{"name":"MacBook Airのマイク",...}` があることは `grep -c '"input"' <prefix>.timed.jsonl` で確認

- [x] **Step 4: Commit**

```bash
git add Apps/Notetake/AppModel.swift Apps/Notetake/LivePanelView.swift
git commit -m "feat(app): show input device and direction in the live panel"
```

---

### Task 6: `DirectionEstimator`（FOA → 方位、純粋計算）

**Files:**
- Create: `Sources/NotetakeCore/Audio/DirectionEstimator.swift`
- Create: `Tests/NotetakeCoreTests/DirectionEstimatorTests.swift`

**Interfaces:**
- Produces:
  - `DirectionEstimator.frameEstimate(w: [Float], y: [Float], x: [Float]) -> (azimuthDeg: Double, confidence: Double)?`（static、`azimuthOffsetDeg`なしの生の値。`E = Σw² <= 0` ならnil）
  - `struct DirectionEstimator { init(azimuthOffsetDeg: Double = 0, minimumFrameConfidence: Double = 0.2); mutating func add(w:y:x:startMS:endMS:); mutating func direction(from startMS: Int64, to endMS: Int64) -> Direction? }`

- [x] **Step 1: 失敗するテストを書く**

```swift
import Foundation
import Testing
@testable import NotetakeCore

/// SN3D正規化のFOA平面波: W = s, X = s·cosθ, Y = s·sinθ（θは数学座標、前=+X、左=+Y、反時計回り）
private func planeWave(thetaDeg: Double, frames: Int = 480, seed: UInt64 = 1) -> (w: [Float], y: [Float], x: [Float]) {
    var state = seed
    func next() -> Float {   // 決定論的な疑似乱数 [-1, 1)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }
    let theta = thetaDeg * .pi / 180
    var w: [Float] = [], y: [Float] = [], x: [Float] = []
    for _ in 0..<frames {
        let s = next()
        w.append(s); x.append(s * Float(cos(theta))); y.append(s * Float(sin(theta)))
    }
    return (w, y, x)
}

@Test func frontSourceIsZeroDegrees() {
    let p = planeWave(thetaDeg: 0)
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg) < 2 || abs(e.azimuthDeg - 360) < 2)
    #expect(e.confidence > 0.95)
}

@Test func rightSourceIsNinetyDegreesClockwise() {
    // 右 = 数学座標で -90°（Yは左が正）→ 時計回り表記で 90°
    let p = planeWave(thetaDeg: -90)
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg - 90) < 2)
}

@Test func leftFrontSourceMapsToClockwise() {
    let p = planeWave(thetaDeg: 60)   // 左前 → 時計回りで 300°
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg - 300) < 2)
}

@Test func diffuseNoiseHasLowConfidence() {
    let a = planeWave(thetaDeg: 0, seed: 1), b = planeWave(thetaDeg: 0, seed: 2), c = planeWave(thetaDeg: 0, seed: 3)
    let e = DirectionEstimator.frameEstimate(w: a.w, y: b.w, x: c.w)!   // 各chが独立ノイズ
    #expect(e.confidence < 0.3)
}

@Test func silenceReturnsNil() {
    let z = [Float](repeating: 0, count: 100)
    #expect(DirectionEstimator.frameEstimate(w: z, y: z, x: z) == nil)
}

@Test func segmentDirectionIsCircularMeanOfFramesInRange() {
    var est = DirectionEstimator()
    let a = planeWave(thetaDeg: 1)      // 時計回り 359°
    let b = planeWave(thetaDeg: -1)     // 時計回り 1°
    est.add(w: a.w, y: a.y, x: a.x, startMS: 0, endMS: 100)
    est.add(w: b.w, y: b.y, x: b.x, startMS: 100, endMS: 200)
    let far = planeWave(thetaDeg: -90)  // 範囲外のフレーム
    est.add(w: far.w, y: far.y, x: far.x, startMS: 5000, endMS: 5100)
    let d = est.direction(from: 0, to: 200)!
    #expect(d.azimuthDeg < 2 || d.azimuthDeg > 358)
    #expect(d.confidence > 0.95)
}

@Test func lowConfidenceFramesAreIgnoredAndNoFramesGivesNil() {
    var est = DirectionEstimator()
    let a = planeWave(thetaDeg: 0, seed: 1), b = planeWave(thetaDeg: 0, seed: 2), c = planeWave(thetaDeg: 0, seed: 3)
    est.add(w: a.w, y: b.w, x: c.w, startMS: 0, endMS: 100)   // 拡散音 → 捨てられる
    #expect(est.direction(from: 0, to: 100) == nil)
}

@Test func azimuthOffsetIsApplied() {
    var est = DirectionEstimator(azimuthOffsetDeg: 90)
    let p = planeWave(thetaDeg: 0)
    est.add(w: p.w, y: p.y, x: p.x, startMS: 0, endMS: 100)
    #expect(abs(est.direction(from: 0, to: 100)!.azimuthDeg - 90) < 2)
}

@Test func framesBeforeQueriedRangeArePruned() {
    var est = DirectionEstimator()
    let p = planeWave(thetaDeg: 0)
    est.add(w: p.w, y: p.y, x: p.x, startMS: 0, endMS: 100)
    _ = est.direction(from: 200, to: 300)
    #expect(est.direction(from: 0, to: 100) == nil)
}
```

- [x] **Step 2: 失敗を確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter DirectionEstimator 2>&1 | tail -5` → コンパイルエラー

- [x] **Step 3: 実装する**

```swift
import Foundation

/// FOA（ACN順 / SN3D: ch0=W, ch1=Y, ch2=Z, ch3=X）から水平方位を推定する純粋計算。
/// フレームごとの推定を貯め、seg の時間範囲で信頼度重みの円平均を取る
public struct DirectionEstimator: Sendable {
    public struct Frame: Sendable, Equatable {
        public var azimuthDeg: Double
        public var confidence: Double
        public var startMS: Int64
        public var endMS: Int64
    }

    /// FOA座標系と機材の「上」がずれていた場合の補正（実機で決める）
    public var azimuthOffsetDeg: Double
    /// これ未満の信頼度のフレームは捨てる
    public var minimumFrameConfidence: Double
    private var frames: [Frame] = []

    public init(azimuthOffsetDeg: Double = 0, minimumFrameConfidence: Double = 0.2) {
        self.azimuthOffsetDeg = azimuthOffsetDeg
        self.minimumFrameConfidence = minimumFrameConfidence
    }

    /// 1フレームの音響インテンシティから方位（時計回り・上基準、補正なし）と信頼度を求める。
    /// 無音（Σw² == 0）ならnil
    public static func frameEstimate(w: [Float], y: [Float], x: [Float]) -> (azimuthDeg: Double, confidence: Double)? {
        var ix = 0.0, iy = 0.0, energy = 0.0
        for i in 0..<min(w.count, y.count, x.count) {
            let wi = Double(w[i])
            ix += wi * Double(x[i])
            iy += wi * Double(y[i])
            energy += wi * wi
        }
        guard energy > 0 else { return nil }
        let thetaDeg = atan2(iy, ix) * 180 / .pi          // 数学座標（反時計回り、前=0）
        let confidence = min(1, (ix * ix + iy * iy).squareRoot() / energy)
        return (Self.normalize(360 - thetaDeg), confidence)
    }

    public mutating func add(w: [Float], y: [Float], x: [Float], startMS: Int64, endMS: Int64) {
        guard let estimate = Self.frameEstimate(w: w, y: y, x: x),
              estimate.confidence >= minimumFrameConfidence
        else { return }
        frames.append(Frame(azimuthDeg: estimate.azimuthDeg, confidence: estimate.confidence,
                            startMS: startMS, endMS: endMS))
    }

    /// [startMS, endMS] と重なるフレームの信頼度重み付き円平均。startMSより前に終わったフレームは捨てる
    public mutating func direction(from startMS: Int64, to endMS: Int64) -> Direction? {
        frames.removeAll { $0.endMS < startMS }
        var sumX = 0.0, sumY = 0.0, weight = 0.0
        for frame in frames where frame.startMS <= endMS && frame.endMS >= startMS {
            let rad = frame.azimuthDeg * .pi / 180
            sumX += frame.confidence * cos(rad)
            sumY += frame.confidence * sin(rad)
            weight += frame.confidence
        }
        guard weight > 0 else { return nil }
        let meanDeg = atan2(sumY, sumX) * 180 / .pi
        let resultant = (sumX * sumX + sumY * sumY).squareRoot() / weight
        return Direction(azimuthDeg: Self.normalize(meanDeg + azimuthOffsetDeg), confidence: resultant)
    }

    private static func normalize(_ deg: Double) -> Double {
        var value = deg.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value == 360 ? 0 : value
    }
}
```

- [x] **Step 4: 通ることを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter DirectionEstimator 2>&1 | tail -5` → 9件PASS。`swift build 2>&1 | grep -i warning` → 出力なし

- [x] **Step 5: Commit**（commit 42d3f44）

```bash
git add Sources/NotetakeCore/Audio/DirectionEstimator.swift Tests/NotetakeCoreTests/DirectionEstimatorTests.swift
git commit -m "feat(core): DirectionEstimator for first-order ambisonics frames"
```

---

### Task 7: iPhone の取り込みを `AVCaptureSession` にして FOA と方位を付ける

**Files:**
- Modify: `Apps/NotetakeMobile/Recorder.swift`（全面）
- Modify: `Apps/NotetakeMobile/MobileModel.swift:150-200`（`startRecording` / `handleFinalPiece`）

**Interfaces:**
- Consumes: `DirectionEstimator`（Task 6）、`InputDevice` / `Direction`（Task 1）、`AudioConverter(from:to:)` / `convert(_:)`、`Transcriber.feed(_:at:)`、`AudioLevel.dbfs(_:)`
- Produces:
  - `Recorder.start(locale:onPiece:)` の `onPiece` が `(TranscriptPiece, Double, Direction?) -> Void` になる
  - `Recorder.currentInput() -> InputDevice`（開始後に有効。開始前は `InputDevice(name: "iPhone", uid: "", spatial: false)`）

- [x] **Step 1: Recorder を書き換える**

方針: `AVAudioEngine`を`AVCaptureSession`に置き換える。対応・非対応で同じ経路。sample bufferのformatは最初のbufferで分かるので、converterは最初の`ingest`で作る。

```swift
import AVFoundation
import Foundation
import NotetakeCore

enum RecorderError: Error {
    case alreadyRunning
    case microphoneUnavailable
}

/// マイク入力（AVCaptureSession）→ AudioConverter → Transcriber(SpeechAnalyzer) をつなぐiPhone側のpipeline。
/// 空間収録（FOA）対応機材ではW chをTranscriberへ、4chをDirectionEstimatorへ流し、final pieceごとに方位を付ける
@available(iOS 26, *)
actor Recorder {
    private struct CapturedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    /// AVCaptureAudioDataOutputのdelegate。CMSampleBufferをAVAudioPCMBufferへコピーしてactorへ渡す
    private final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        let continuation: AsyncStream<CapturedBuffer>.Continuation
        let channelLayout: AVAudioChannelLayout?

        init(continuation: AsyncStream<CapturedBuffer>.Continuation, channelLayout: AVAudioChannelLayout?) {
            self.continuation = continuation
            self.channelLayout = channelLayout
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else { return }
            let format: AVAudioFormat?
            if let channelLayout, asbd.pointee.mChannelsPerFrame == channelLayout.channelCount {
                format = AVAudioFormat(streamDescription: asbd, channelLayout: channelLayout)
            } else {
                format = AVAudioFormat(streamDescription: asbd)
            }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard let format, frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            pcm.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
            guard status == noErr else { return }
            continuation.yield(CapturedBuffer(buffer: pcm))
        }
    }

    private var session: AVCaptureSession?
    private var delegate: SampleDelegate?
    private let queue = DispatchQueue(label: "io.github.bash0c7.notetake.capture")
    private var transcriber: Transcriber?
    /// 取り込みformat → Transcriber input format（非FOA時）、または W ch のmono float → Transcriber input format（FOA時）
    private var converter: AudioConverter?
    /// 取り込みformat → 4ch Float32 非interleaved（FOA時のみ）
    private var foaConverter: AudioConverter?
    private var estimator = DirectionEstimator()
    private var input = InputDevice(name: "iPhone", uid: "", spatial: false)
    private var originMS: Int64 = 0
    private var sampleTime: AVAudioFramePosition = 0
    private var lastLevelDBFS: Double = -120

    private var bufferContinuation: AsyncStream<CapturedBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?

    func currentInput() -> InputDevice { input }

    func start(
        locale: Locale,
        onPiece: @escaping @Sendable (TranscriptPiece, Double, Direction?) -> Void
    ) async throws {
        guard session == nil else { throw RecorderError.alreadyRunning }
        guard let microphone = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified) else {
            throw RecorderError.microphoneUnavailable
        }
        let deviceInput = try AVCaptureDeviceInput(device: microphone)
        let spatial = deviceInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
        input = InputDevice(name: microphone.localizedName, uid: microphone.uniqueID, spatial: spatial)

        let origin = Date()
        originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
        let transcriber = try await Transcriber(locale: locale, origin: origin)
        self.transcriber = transcriber
        self.converter = nil
        self.foaConverter = nil
        self.estimator = DirectionEstimator()
        self.sampleTime = 0
        self.lastLevelDBFS = -120

        let pieces = try await transcriber.start()

        let (bufferStream, bufferContinuation) = AsyncStream<CapturedBuffer>.makeStream()
        self.bufferContinuation = bufferContinuation

        let foaLayout = spatial ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_HOA_ACN_SN3D | 4) : nil
        let delegate = SampleDelegate(continuation: bufferContinuation, channelLayout: foaLayout)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(delegate, queue: queue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            session.commitConfiguration()
            bufferContinuation.finish()
            self.bufferContinuation = nil
            self.transcriber = nil
            try? await transcriber.finish()
            throw RecorderError.microphoneUnavailable
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        if spatial {
            deviceInput.multichannelAudioMode = .firstOrderAmbisonics
            output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
        }
        session.commitConfiguration()
        session.startRunning()

        self.session = session
        self.delegate = delegate

        feedTask = Task {
            for await captured in bufferStream {
                await self.ingest(captured.buffer)
            }
        }

        forwardTask = Task {
            for await piece in pieces where piece.isFinal {
                let (level, direction) = await self.finish(piece: piece)
                onPiece(piece, level, direction)
            }
        }
    }

    func stop() async throws {
        guard let session else { return }
        session.stopRunning()
        self.session = nil
        self.delegate = nil

        bufferContinuation?.finish()
        bufferContinuation = nil
        await feedTask?.value
        feedTask = nil

        let transcriber = self.transcriber
        self.transcriber = nil
        self.converter = nil
        self.foaConverter = nil

        do {
            try await transcriber?.finish()
        } catch {
            await forwardTask?.value
            forwardTask = nil
            throw error
        }
        await forwardTask?.value
        forwardTask = nil
    }

    private func ingest(_ buffer: sending AVAudioPCMBuffer) async {
        guard let transcriber else { return }
        let sampleRate = buffer.format.sampleRate
        let frames = AVAudioFramePosition(buffer.frameLength)
        let startMS = originMS + Int64(Double(sampleTime) * 1000 / sampleRate)
        let endMS = originMS + Int64(Double(sampleTime + frames) * 1000 / sampleRate)

        let monoSource: AVAudioPCMBuffer
        if input.spatial, buffer.format.channelCount == 4 {
            guard let foa = try? foaBuffer(from: buffer), let data = foa.floatChannelData else { return }
            let count = Int(foa.frameLength)
            let w = Array(UnsafeBufferPointer(start: data[0], count: count))
            let y = Array(UnsafeBufferPointer(start: data[1], count: count))
            let x = Array(UnsafeBufferPointer(start: data[3], count: count))
            estimator.add(w: w, y: y, x: x, startMS: startMS, endMS: endMS)
            guard let mono = Self.monoBuffer(samples: w, sampleRate: foa.format.sampleRate) else { return }
            monoSource = mono
        } else {
            monoSource = buffer
        }

        if converter == nil {
            converter = try? AudioConverter(from: monoSource.format, to: transcriber.inputFormat)
        }
        guard let converter, let converted = try? converter.convert(monoSource) else { return }
        lastLevelDBFS = AudioLevel.dbfs(converted)
        let convertedFrames = AVAudioFramePosition(converted.frameLength)
        await transcriber.feed(converted, at: sampleTime)
        sampleTime += convertedFrames
    }

    /// 取り込みbufferを4ch Float32 非interleavedへ（初回にconverterを作る）
    private func foaBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if foaConverter == nil {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 4, interleaved: false)
            else { throw RecorderError.microphoneUnavailable }
            foaConverter = try AudioConverter(from: buffer.format, to: target)
        }
        return try foaConverter!.convert(buffer)
    }

    private static func monoBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    private func finish(piece: TranscriptPiece) -> (Double, Direction?) {
        let direction = input.spatial ? estimator.direction(from: piece.startMS, to: piece.endMS) : nil
        return (lastLevelDBFS, direction)
    }
}
```

注意:
- `AVAudioSession.setCategory`は呼ばない（`AVCaptureSession`が`automaticallyConfiguresApplicationAudioSession`で自分で設定する）
- `sampleTime`はTranscriberへ渡したフレーム数（変換後）で進める。`startMS` / `endMS`の計算は変換前のsample rateで行うため、`ingest`先頭で計算している
- `AudioConverter`（NotetakeCore）が4ch→4ch Float32 / 1ch→Transcriber formatの両方を担う。FOAのchannel layoutを持つformatから`commonFormat`のformatへの変換が`AVAudioConverter`で拒否された場合は、`foaBuffer`を`AVAudioConverter`を使わず手でde-interleave（Int16→Float32）する実装に置き換える（実機で判明する事項。planではAudioConverter経由を第一候補とする）

- [x] **Step 2: MobileModel を直す**

`startRecording` の closure を `{ piece, dbfs, direction in ... await model.handleFinalPiece(piece, dbfs: dbfs, direction: direction, session: session) }` に。`handleFinalPiece(_:dbfs:direction:session:)` で:

```swift
let input = await recorder.currentInput()
let segment = Segment(
    id: UUID(), session: session, seq: 0,
    device: settings.deviceID, deviceName: settings.deviceName, owner: settings.ownerName,
    platform: .ios, source: .mic, input: input,
    start: piece.startMS, end: piece.endMS, text: piece.text,
    confidence: piece.confidence, levelDBFS: dbfs, direction: direction
)
```

- [x] **Step 3: コンパイルを通す**（2026-09-13 `make verify`で確認）

Run: iOS app のコンパイル（検証コマンド）→ `BUILD SUCCEEDED`。`swift build 2>&1 | grep -E "error|warning"` → 出力なし（Coreに変更が無いことの確認）

- [x] **Step 4: Commit**

```bash
git add Apps/NotetakeMobile/Recorder.swift Apps/NotetakeMobile/MobileModel.swift
git commit -m "feat(ios): capture with AVCaptureSession, first-order ambisonics and per-segment direction"
```

---

### Task 8: 整形（polish）を時刻無しの対話にする

**Files:**
- Modify: `Sources/NotetakeCore/Polish/PolishChunker.swift`（`PolishTurn` / `PolishedTurn` / `turns` / `merge`）
- Modify: `Sources/NotetakeCore/Polish/PolishRenderer.swift`
- Modify: `Sources/notetaked/Polish/Polisher.swift:23-27`（instructions）
- Modify: `Sources/notetaked/Commands/PolishCommand.swift:44-62`
- Modify: `Tests/NotetakeCoreTests/PolishChunkerTests.swift`、`Tests/NotetakeCoreTests/PolishRendererTests.swift`

**Interfaces:**
- Produces:
  - `PolishTurn { speaker: String; text: String }`、`PolishedTurn { speaker: String; text: String; polished: Bool }`（`startMS`を削除）
  - `PolishRenderer.markdown(_ turns: [PolishedTurn], recordedAt: Date, timeZone: TimeZone) -> String`
  - `PolishRenderer.participants(_ turns: [PolishedTurn]) -> [String]`（登場順・重複なし）

- [x] **Step 1: テストを新仕様に書き換える**

`PolishChunkerTests.swift`: `PolishTurn(...)` / `PolishedTurn(...)` から `startMS:` 引数を削除。`mergeExactCountAssignsStartMSAndPolishedTrue` を `mergeExactCountUsesOutputAndPolishedTrue` に改名し期待値から `startMS` を除く。`mergeCountMismatchAssignsNilStartMS` を `mergeCountMismatchStillAdoptsOutput` に改名し、件数不一致でも出力がそのまま `polished: true` で採用されることだけを確認する。

`PolishRendererTests.swift` を全面的に置き換える:

```swift
import Foundation
import Testing
@testable import NotetakeCore

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let recordedAt = Date(timeIntervalSince1970: 1_789_300_000)   // 2026-09-14 JST

@Test func rendersHeaderWithDateAndParticipantsThenDialogue() {
    let turns = [
        PolishedTurn(speaker: "小芝", text: "こんにちは", polished: true),
        PolishedTurn(speaker: "田中", text: "うん", polished: true),
        PolishedTurn(speaker: "小芝", text: "そう", polished: true),
    ]
    let result = PolishRenderer.markdown(turns, recordedAt: recordedAt, timeZone: tokyo)
    #expect(result == "# 2026-09-14 小芝、田中\n\n**小芝**: こんにちは\n**田中**: うん\n**小芝**: そう\n")
}

@Test func replacesNewlinesWithSpace() {
    let turn = PolishedTurn(speaker: "小芝", text: "a\nb", polished: true)
    let result = PolishRenderer.markdown([turn], recordedAt: recordedAt, timeZone: tokyo)
    #expect(result.hasSuffix("**小芝**: a b\n"))
}

@Test func appendsFailureFooterWhenAnyTurnNotPolished() {
    let turns = [
        PolishedTurn(speaker: "小芝", text: "こんにちは", polished: true),
        PolishedTurn(speaker: "田中", text: "うん", polished: false),
    ]
    let result = PolishRenderer.markdown(turns, recordedAt: recordedAt, timeZone: tokyo)
    #expect(result.hasSuffix("**田中**: うん\n\n> 整形に失敗したturn: 1件（原文のまま）\n"))
}

@Test func participantsAreInOrderOfAppearanceWithoutDuplicates() {
    let turns = [
        PolishedTurn(speaker: "田中", text: "a", polished: true),
        PolishedTurn(speaker: "小芝", text: "b", polished: true),
        PolishedTurn(speaker: "田中", text: "c", polished: true),
    ]
    #expect(PolishRenderer.participants(turns) == ["田中", "小芝"])
}

@Test func polishedMarkdownOfNoTurnsIsEmpty() {
    #expect(PolishRenderer.markdown([], recordedAt: recordedAt, timeZone: tokyo) == "")
}
```

- [x] **Step 2: 失敗を確認する**（2026-09-13 `make verify`で確認）

Run: `swift test --filter PolishRenderer 2>&1 | tail -5` → コンパイルエラー

- [x] **Step 3: 実装する**

`PolishChunker.swift`: `PolishTurn` / `PolishedTurn` から `startMS` を削除（init含む）。`turns(from:)` は `PolishTurn(speaker: utterance.speaker, text: utterance.text)`。`merge` は件数一致・不一致とも `PolishedTurn(speaker: item.speaker, text: item.text, polished: true)`、失敗は `PolishedTurn(speaker: $0.speaker, text: $0.text, polished: false)`。doc commentから `startMS` の記述を消す。

`PolishRenderer.swift`:

```swift
import Foundation

/// 整形済みturn列を対話だけのMarkdown（`<start>.polished.md`）へ変換する純粋関数。時刻は出さない
public enum PolishRenderer {
    /// 先頭 "# yyyy-MM-dd 参加者、参加者" + 空行、以降 "**話者**: 本文" を1行ずつ。本文中の改行は空白に置換。
    /// polished == false のturnが1件以上あれば末尾に失敗件数の注記。空配列なら ""
    public static func markdown(_ turns: [PolishedTurn], recordedAt: Date, timeZone: TimeZone) -> String {
        guard !turns.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var result = "# \(formatter.string(from: recordedAt)) \(participants(turns).joined(separator: "、"))\n\n"
        var failureCount = 0
        for turn in turns {
            let text = String(turn.text.map { $0.isNewline ? " " : $0 })
            result += "**\(turn.speaker)**: \(text)\n"
            if !turn.polished { failureCount += 1 }
        }
        if failureCount > 0 {
            result += "\n> 整形に失敗したturn: \(failureCount)件（原文のまま）\n"
        }
        return result
    }

    /// 登場順・重複なしの話者ラベル
    public static func participants(_ turns: [PolishedTurn]) -> [String] {
        var seen = Set<String>()
        return turns.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }
}
```

`Polisher.swift` の instructions 末尾に `時刻や場所の情報は入力に無いので扱わない。` を足す。

`PolishCommand.runPolish`: `let records = NDJSON.decodeAll(text)` として `Reconciler.fold(records)`。収録日は先頭の session record から:

```swift
guard case .session(let sessionRecord)? = records.first(where: {
    if case .session = $0 { return true } else { return false }
}) else {
    throw ValidationError("no session record in \(timedPath)")
}
let recordedAt = Date(timeIntervalSince1970: Double(sessionRecord.started) / 1000)
```

`PolishRenderer.markdown(polished, recordedAt: recordedAt, timeZone: .current)`。

- [x] **Step 4: 通ることを確認する**（2026-09-13 `make verify`で確認）

Run: `swift test 2>&1 | tail -5` → 全件PASS。`swift build 2>&1 | grep -E "error|warning"` → 出力なし
Run（Apple Intelligence有効なら）: `make daemon && .build/release/notetaked polish <保存先>/<prefix>.timed.jsonl` → `<prefix>.polished.md` の先頭が `# yyyy-MM-dd 名前` で、行に時刻が無いことを `head -3` で確認

- [x] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Polish Sources/notetaked/Polish/Polisher.swift Sources/notetaked/Commands/PolishCommand.swift Tests/NotetakeCoreTests/PolishChunkerTests.swift Tests/NotetakeCoreTests/PolishRendererTests.swift
git commit -m "feat(polish): render dialogue only with a date/participants header, no timestamps"
```

---

### Task 9: HANDOFF.md に検証手順を追記する

**Files:**
- Modify: `HANDOFF.md`（「branchに入っているもの」表と「Mac側で行う検証」）

- [x] **Step 1: 追記する**

表に行を足す:

```
| L 場所情報 / 対話整形 | segの`input` / `direction`、`LocationLabel`、`DirectionEstimator`、iPhone `AVCaptureSession` + FOA、状態行とパネルの場所表示、polishの時刻無し対話出力 | `docs/superpowers/plans/2026-09-13-spatial-location-polish.md` |
```

「Mac側で行う検証」に節を足す:

```
### 6. 場所情報 / 対話整形（L）

1. Mac: 収録開始→発話→停止。`timed.jsonl` の seg に `"input":{"name":"MacBook Airのマイク","uid":"BuiltInMicrophoneDevice","spatial":false}`、final.md の行が `**話者**（Mac）:`。パネル状態行に `入力: MacBook Airのマイク（空間: 非対応）`
2. AirPods Pro 3 を接続して既定入力にし「区切る」→ 新しいprefixのsegが `"name":"ゆふAirPods Pro 3"`、行が `（AirPods）`
3. `notetaked polish <prefix>.timed.jsonl` → 先頭 `# yyyy-MM-dd 参加者`、行に時刻無し
4. iPhone（証明書後）: 初回起動で `input.spatial` を確認。true なら机に平置きし、上端側から `say` → `azimuth_deg ≈ 0`、右側から → `≈ 90`。ずれていれば `Recorder` の `DirectionEstimator(azimuthOffsetDeg:)` を決める。false なら `direction` 無し・`input.name` のみで完了
```

- [x] **Step 2: Commit**

```bash
git add HANDOFF.md
git commit -m "docs(handoff): verification steps for input device, direction and dialogue polish"
```
