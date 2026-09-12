# M3 話者分離（Mac）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mac daemonのmic / system各streamで声の埋め込みによる話者分離を行い、segに`speaker {local, global, embedding}`を載せ、Mac横断の`SpeakerRegistry`で大域話者id（`g1`…）を付ける。命名はライブパネル（既存の改名popover）から。`<prefix>.speakers.json`と大域プロファイル`~/Library/Application Support/Notetake/speakers.json`（命名済みのみ）を書く。

**Architecture:** FluidAudio v0.15.7（`DiarizerManager` / `DiarizerModels`）を`NotetakeDiarization` targetだけが依存し、`Diarizer` actorが「16kHz mono floatを10秒溜めるごとに`performCompleteDiarization(chunk, sampleRate: 16000, atTime:)`を呼び、絶対時刻（epoch ms）の`SpeakerTurn`列を返す」だけを提供する。`NotetakeCore`の純粋関数`Aligner`がTranscriberのfinal結果（run単位の時間範囲）を話者turn境界で分割し、`SpeakerRegistry`（純粋・Codable）がcosine最近傍で大域idを付ける。

**Spec:** `docs/superpowers/specs/2026-09-12-notetake-design.md`「話者分離（Core ML）」

**環境:** 実装セッションにSwiftツールチェーン無し。Core純粋ロジックはTDD（テスト先行、実行はMac側）。FluidAudioのAPIはv0.15.7のソースで確認済み（下記「確認済みAPI」）。

## 確認済みAPI（FluidAudio v0.15.7ソース）

- `import FluidAudio`。`DiarizerConfig(clusteringThreshold: Float = 0.7, chunkDuration: Float = 10.0, ...)`、`.default`
- `DiarizerModels.downloadIfNeeded(to: URL? = nil, configuration: MLModelConfiguration? = nil, progressHandler: ProgressHandler? = nil) async throws -> DiarizerModels`（`ProgressHandler = @Sendable (DownloadProgress) -> Void`、`DiarizerModels: Sendable`。既定の保存先は`~/Library/Application Support/FluidAudio/Models/…`、初回はHugging Faceから取得）
- `DiarizerManager(config:)`（非Sendable class → actor内で保持）、`initialize(models: consuming DiarizerModels)`、`performCompleteDiarization<C: RandomAccessCollection<Float>>(_ samples: C, sampleRate: Int = 16000, atTime startTime: TimeInterval = 0) throws -> DiarizationResult`
- `DiarizationResult.segments: [TimedSpeakerSegment]`（`speakerId: String`、`embedding: [Float]`（256）、`startTimeSeconds: Float`、`endTimeSeconds: Float`。`atTime`分が加算済み）。chunk横断の話者id一貫性は`DiarizerManager.speakerManager`が内部で保つ
- package: `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7")`、product `FluidAudio`。platforms macOS 14 / iOS 17。binaryTarget（NemoTextProcessing xcframework）を含む

## 設計判断

| 論点 | 決定 |
|---|---|
| 分離結果待ち | Transcriberのfinal pieceは、その時間範囲を分離結果が覆うまで`Aligner`が保留（上限 = chunk 10秒 + 2秒）。上限超過は話者未定で出す。**specの「本文を即表示して後から話者だけ差し替え」は採らず**、保留中はvolatile行で途中経過が見える（timed.jsonlにはfinalだけ書くという原則を保ち、seg更新レコードを増やさないため） |
| run時間範囲 | `TranscriptPiece.runs: [TranscriptRun]`（run毎のtext・startMS・endMS）をTranscriberが`AttributedString`の`audioTimeRange`から作る。runに時間範囲が無ければpiece全体の範囲 |
| local→global | `SpeakerRegistry.assign(streamKey:localID:embedding:)`。同一stream内で既に対応が決まったlocal idは同じglobalに固定し（chunk横断の揺れを抑える）、新規local idはcosine最近傍（閾値0.7）。閾値未満なら新規`g<N>`（Nは既存最大+1）。centroidは所属埋め込みの正規化平均 |
| 大域プロファイル | 命名済み話者のみ`~/Library/Application Support/Notetake/speakers.json`へ保存。serve起動時に読み込み`SpeakerRegistry`の初期profilesにする。命名・停止時に書く |
| `--diarize` | `serve --diarize/--no-diarize`（既定on）。appは指定しない（on）。モデル取得中は`log`イベントで進捗を出す |

## Interfaces（全agent共通の契約）

```swift
// Sources/NotetakeCore/Transcribe/TranscriptRun.swift（Speech非依存）
public struct TranscriptRun: Sendable, Equatable { public var text: String; public var startMS: Int64; public var endMS: Int64; public init(...) }
// TranscriptPiece に追加: public var runs: [TranscriptRun] = []（init引数末尾、既定[]）

// Sources/NotetakeCore/Speaker/SpeakerTurn.swift
public struct SpeakerTurn: Sendable, Equatable { public var localID: String; public var startMS: Int64; public var endMS: Int64; public var embedding: [Float]; public init(...) }

// Sources/NotetakeCore/Speaker/Aligner.swift（純粋）
public struct AlignedPiece: Sendable, Equatable {
    public var text: String; public var startMS: Int64; public var endMS: Int64; public var confidence: Double?
    public var localSpeaker: String?; public var embedding: [Float]?
}
public struct Aligner: Sendable {
    public struct Config: Sendable { public var holdLimitMS: Int64 = 12_000; public init() }
    public init(config: Config = Config())
    public mutating func add(turns: [SpeakerTurn], coveredUntilMS: Int64)   // 分離済み範囲を進める（単調増加）
    public mutating func add(piece: TranscriptPiece)                         // final pieceを保留列へ
    public mutating func drain(nowMS: Int64) -> [AlignedPiece]               // endMS <= coveredUntilMS の保留pieceを分割して出す。nowMS - piece.endMS > holdLimitMS なら覆われていなくても出す（話者は分かる範囲で付け、無ければnil）
    public mutating func flush() -> [AlignedPiece]                           // 停止時: 残り全部を今ある turns で分割して出す
}
// 分割規則: pieceの各runに最大重なりのturnを割り当て（重なり無しは直前runの話者を引き継ぎ、先頭なら次のrunの話者、turnが1つも無ければnil）。連続する同一話者runを1つのAlignedPieceにまとめる（text = runのtext連結、start = 先頭runのstart、end = 末尾runのend、confidence = pieceのもの、embedding = そのturnの埋め込み）。runsが空のpieceは全体で1つとして扱う（textとpiece範囲で判定）

// Sources/NotetakeCore/Speaker/SpeakerRegistry.swift（純粋・Codable）
public struct SpeakerProfile: Codable, Sendable, Equatable { public var id: String; public var name: String?; public var centroid: [Float]; public var count: Int; public init(...) }
public struct SpeakerRegistry: Sendable {
    public struct Config: Sendable { public var threshold: Float = 0.7; public init() }
    public init(config: Config = Config(), profiles: [SpeakerProfile] = [])
    public private(set) var profiles: [SpeakerProfile]
    public mutating func assign(streamKey: String, localID: String, embedding: [Float]) -> String   // global id
    public mutating func setName(_ name: String, for id: String)
    public func name(for id: String) -> String?
    public var namedProfiles: [SpeakerProfile]   // name != nil
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float   // 長さ不一致・零ベクトルは0
}
// SessionStore に追加: public nonisolated let speakersURL（<prefix>.speakers.json）、public func writeSpeakers(_ profiles: [SpeakerProfile]) throws（JSON、sortedKeys、atomic）

// Sources/NotetakeDiarization/Diarizer.swift
@available(macOS 14, iOS 17, *)
public actor Diarizer {
    public struct Output: Sendable { public var turns: [SpeakerTurn]; public var coveredUntilMS: Int64 }
    public static func prepareModels(progress: @escaping @Sendable (Double) -> Void) async throws -> DiarizerModels   // downloadIfNeeded。progressは0...1
    public init(models: DiarizerModels, originMS: Int64, chunkSeconds: Double = 10, clusteringThreshold: Float = 0.7)
    public func feed(_ samples: [Float]) throws -> Output?   // 16kHz mono。chunk分溜まるごとにperformCompleteDiarizationしてOutputを返す（それ以外nil）
    public func flush() throws -> Output?                    // 残り（1秒以上あれば）を処理
}
// coveredUntilMS = originMS + 処理済みsample数/16000*1000。turn.startMS/endMS = originMS + seconds*1000
```

## Tasks

### Task 1（Core、TDD）: TranscriptRun / SpeakerTurn / Aligner / SpeakerRegistry / SessionStore.writeSpeakers
- Test: `AlignerTests.swift`（1話者→1piece / 2turnで分割 / 未カバーは保留 / 上限超過で話者nil / flush / 重なり無しrunの引き継ぎ / runs空piece）、`SpeakerRegistryTests.swift`（新規g1 / 類似→同じidとcentroid更新 / 非類似→g2 / 同stream同localは固定 / seed済み命名profileに一致・名前保持・採番継続 / cosineの零・長さ不一致 / Codable round trip）、`SessionStoreTests`にwriteSpeakers
- [ ] Step 1 テスト → Step 2 実装 → commit `feat(core): aligner, speaker registry, transcript runs`

### Task 2（Diarization target・Transcriber）: Package.swift / `NotetakeDiarization` / `TranscriptPiece.runs`
- Package.swift: dependency FluidAudio exact 0.15.7、target `NotetakeDiarization`（deps: NotetakeCore, FluidAudio）、`notetaked`のdepsに追加。products にlibrary追加は不要
- `Transcriber.makePiece`: `text.runs`から`TranscriptRun`（`run.audioTimeRange`が無ければpiece範囲）
- [ ] commit `feat(diarization): FluidAudio-backed Diarizer actor and transcript runs`

### Task 3（daemon統合・app）
- `CaptureStream`: 16kHz mono Float32へ第2の`AudioConverter`、`Diarizer`へfeed、`Aligner`で分割、`StreamEvent.final(AlignedPiece, levelDBFS:)`へ変更。`init(source:capture:locale:diarizerModels: DiarizerModels?)`。diarizerがnilなら分割せずrunsを無視して従来どおり（localSpeaker nil）
- `ServeSession`: `SpeakerRegistry`（serve起動時に大域profileを読む）。`handleFinal`で`assign`→`SpeakerTag(local:global:embedding:)`。`rename_speaker`で`setName`+`writeSpeakers`+大域profile保存。`stopCapture`で`writeSpeakers`+大域profile保存
- `ServeCommand`: `--diarize`（既定on）、`Diarizer.prepareModels`（進捗を`log`）。`SpeakerProfileStore`（`~/Library/Application Support/Notetake/speakers.json`のload/save）
- app: `AppModel.lastLog`（`.log`の最新1行）をメニューの状態行の下に表示（モデル取得進捗）
- [ ] commit `feat(daemon,app): wire diarization into serve`

### Task 4（docs）: spec追記（保留方式の決定）、HANDOFF（Mac検証手順: 2話者音源）
