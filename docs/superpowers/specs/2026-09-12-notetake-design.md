# Notetake / notetaked — 常駐マルチデバイス文字起こし 設計・実装計画

## Context

会議（特にビデオ会議）の「いつ・だれが・何を話したか」を、外部AIを使わず全てApple on-device APIとCore MLで、高速・リアルタイムに文字起こしする。Macのメニューバー常駐appがUIとコントロールを担い、認識エンジンはMacのdaemon(CLI)・iPhone app・Watch appに分散させ、各デバイスの認識結果をMacに集約してストリーミング的にファイルへ吐き出す。吐き出したファイルは後から読み込み、会話文として丁寧な文章に整形する。音声そのものは成果物として残さない。

Mac側が一次のリアルタイムtranscript（コピペ可能なライブパネル）を作り、iPhone / Watchからの情報は遅延を許容して「後追いで精度を上げる材料」として既存の発話にマージ反映する。

## 環境（確認済み）

- 開発機: Apple M3 / macOS 26.5.2 / Xcode 26.5（SDK: macOS 26.5, iOS 26.5, watchOS 26.5）/ Swift 6.3.2
- `xcodegen`導入済み（`/opt/homebrew/bin/xcodegen`）。tuistは無し
- code signing: 有効な"Apple Development" identityあり。Team ID `SM5792D355`
- 実機: iPhone 14 Pro / 15以降でiOS 26以上、Apple Watchあり
- プロジェクトディレクトリ`~/dev/src/github.com/bash0C7/notetaked`は空。git未初期化

## モデル分担（user指定）

- **Fable**: 全体検討・設計判断・subagentの統制・レビュー・統合
- **Sonnet**: コード記述（各taskの実装。純粋ロジックはTDD）
- **Haiku**: 決定論的コマンド実行（`swift build` / `swift test` / `xcodegen generate` / `xcodebuild` / `devicectl` / gitのread系）と結果報告

## user決定事項

| 論点 | 決定 |
|---|---|
| iPhone→Mac通信 | Network framework + Bonjour（`_notetake._tcp`、TLS PSK、NDJSON） |
| 話者の決め方 | デバイス=話者を基本にしつつ、**Core ML話者分離をv1に含める**（声の埋め込みで話者を分け、デバイス横断で同一話者を統合） |
| Watchのバックグラウンド録音 | 前面のみで割り切る（収録中はWatch appを表示したまま） |
| iPhone / Watch情報の扱い | 遅延許容。後追いでMac側transcriptの精度を上げる材料として反映 |
| Mac側UI | メニューバー常駐 + リアルタイム表示パネル（テキスト選択・コピー可） |
| 保存先 | GUIのapp設定で事前に指定したディレクトリ（daemonは引数で受け取る） |
| ファイル名 | 録音開始日時`yyyy-mm-dd_hhmmss`（ローカル時刻）を接頭辞にし、1回の収録で複数ファイルを出す: ひたすらリアルタイムに書く本文 / 時刻情報付きのストリーム / 最後に書く完成版 |

## Apple API確定事実（一次資料で確認済み）

### Speech framework（SpeechAnalyzer）
- 対応platform: iOS / iPadOS / macOS / visionOS / tvOS 26+。**watchOSは非対応**（legacy `SFSpeechRecognizer`も非対応）→ Watchは音声をiPhoneへ送って認識を委譲
- **話者分離の公開APIはiOS 27 / macOS 27 SDKにも無い** → 第三者Core MLモデルを使う
- 認可は**マイク権限のみ**（`NSSpeechRecognitionUsageDescription`不要、完全on-device）
- `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`。`attributeOptions: [.audioTimeRange, .transcriptionConfidence]`で結果`AttributedString`のrunごとに時間範囲と信頼度が付く。`SpeechModuleResult.range: CMTimeRange` / `.isFinal` / `.resultsFinalizationTime`。`reportingOptions: [.volatileResults]`で途中結果
- 入力は`AnalyzerInput(buffer:bufferStartTime:)`。**フォーマット変換はしてくれない** → `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`へ`AVAudioConverter`で合わせる
- ja-JPは`SpeechTranscriber.supportedLocales`に含まれる。`AssetInventory.assetInstallationRequest(supporting:)`で取得後は完全オフライン
- 複数`SpeechAnalyzer`同時実行可（mic用とsystem audio用の2本は問題無し）。上限超過は`SFSpeechError.Code.insufficientResources`
- ハードウェア: Apple silicon Mac / iPhoneはA16以降。`SpeechTranscriber.isAvailable`で判定し、非対応なら`DictationTranscriber`

### Macのシステム音声キャプチャ
- Core Audio process tap（macOS 14.2+）: `CATapDescription(stereoGlobalTapButExcludeProcesses:)` → `AudioHardwareCreateProcessTap` → `AudioHardwareCreateAggregateDevice`（`kAudioAggregateDeviceTapListKey`）→ IOProcで読む
- 権限は`NSAudioCaptureUsageDescription`（「システム音声の録音」枠）。Screen Recording権限は不要。ScreenCaptureKitはScreen Recording権限が要るので使わない
- CLIでも`-sectcreate __TEXT __info_plist`でInfo.plistを埋め込めば権限取得の実例あり。appが子processとして起動した場合の権限帰属は一次資料で未確認 → M2で実機確認（後述のリスク）

### watchOS
- 通常appに低レベルsocket通信は提供されない（TN3135）→ Watch→Mac直接は不可。**WatchConnectivity経由でiPhoneを中継**
- `WCSession.transferFile`はキューされバックグラウンドでも配送、サイズ上限なし。`sendMessage`系は`isReachable`必須
- 手首を下ろした後の録音継続は`audio` background mode + HKWorkoutSessionの併用が実例（一次資料は部分的）→ v1は前面のみ

### iPhone↔Mac
- `NWParameters.includePeerToPeer = true`でAWDL（peer-to-peer Wi-Fi）越しのBonjour発見が共通Wi-Fi無しでも成立
- `audio` background modeで録音中はprocessが生きるので通信も継続
- Info.plist: `NSLocalNetworkUsageDescription`, `NSBonjourServices`（`_notetake._tcp`）, `NSMicrophoneUsageDescription`

### Foundation Models
- Apple Intelligence対応機（M3 Macは可、iPhone 15 Pro以降）、iOS / macOS 26+。日本語対応
- **contextはsessionあたり入出力合計4096 token固定** → 分割処理必須
- `LanguageModelSession(instructions:)` / `respond(to:)` / `streamResponse(to:)` / `@Generable`。可用性は`SystemLanguageModel.default.availability`
- CLI / daemonからの利用可（macOS 27同梱の`fm` CLIが同様の形）

### NaturalLanguage
- `NLEmbedding.sentenceEmbedding(for: .japanese)`は**存在しない**。文類似度は自前の文字bigram Dice係数で十分（決定論的・依存無し）。`NLTokenizer`は日本語の文分割に使える

## アーキテクチャ

```
┌ Mac ──────────────────────────────────────────────────────────────────┐
│ Notetake.app（メニューバー常駐 + ライブパネル）                          │
│   └─ 子process起動・stdin/stdout NDJSONで制御/状態受信                    │
│ notetaked（CLI daemon = ハブ）                                          │
│   ├ MicCapture(AVAudioEngine) ─┬→ Transcriber(SpeechAnalyzer #1) ┐        │
│   │                            └→ Diarizer(Core ML)   ───────────┼→ Aligner │
│   ├ SystemAudioCapture(process tap) ┬→ Transcriber #2 ┐          │   ↓     │
│   │                                 └→ Diarizer ──────┼→ Aligner ┘  seg    │
│   ├ PeerListener(NWListener Bonjour/TLS) ← iPhone segments ────────→ seg   │
│   ├ Reconciler（全segの純粋fold → utterances、後追い更新）                 │
│   ├ SpeakerRegistry（埋め込みclustering、命名、永続化）                     │
│   └ SessionStore: <start>.live.txt(追記) / <start>.timed.jsonl(追記)        │
│                   / <start>.final.md(停止時・遅延分到着時に再生成)           │
│ notetaked polish <timed.jsonl>: Reconciler → Foundation Models → polished.md │
└───────────────────────────────────────────────────────────────────────┘
        ▲ NDJSON over TLS(PSK) / Bonjour _notetake._tcp（未接続時はoutboxに蓄積）
┌ iPhone ─────────────────────────┐    ┌ Watch ──────────────────────────┐
│ Mic → Transcriber + Diarizer    │ ←──│ Mic → 20秒AAC小片 → WCSession    │
│ → seg → Outbox → PeerClient      │    │   transferFile（前面のみ）        │
│ Watch小片 → 専用Transcriber → seg │    │ 送信完了で小片削除                 │
└─────────────────────────────────┘    └─────────────────────────────────┘
```

### コンポーネント責務

| 単位 | 責務 | 依存 |
|---|---|---|
| `NotetakeCore`（SwiftPM library、全platform共有） | `Segment`等のモデル / NDJSON codec / `Reconciler` / `SpeakerRegistry`のclustering算術 / `TranscriptRenderer`(Markdown) / `Outbox` / `Transcriber`(SpeechAnalyzer wrapper、`#if canImport(Speech)`) / clock offset算術 | Foundation, Speech, AVFAudio |
| `NotetakeDiarization`（SwiftPM target、macOS/iOSのみ） | Core ML話者分離wrapper: 16kHz mono float → 話者turn（時間範囲・local speaker id・埋め込みvector） | FluidAudio（後述の調査で確定） |
| `notetaked`（SwiftPM executable、macOS） | 上図のハブ。subcommand: `serve`（常駐）/ `polish`（整形）/ `render`（timed.jsonl→final.md再生成） | Core, Diarization, CoreAudio, FoundationModels, Network |
| `Notetake`（macOS app、XcodeGen） | `MenuBarExtra` + ライブパネルWindow。daemon起動監督、設定、話者命名、コピー、polish実行 | Core |
| `NotetakeMobile`（iOS app） | Mic認識 + 話者分離 + 送信 + Watch中継 | Core, Diarization, Network, WatchConnectivity |
| `NotetakeWatch`（watchOS app） | 前面録音 → AAC小片 → iPhoneへ転送 | Core（モデルのみ）, WatchConnectivity |

## データモデルとファイル

### Segment（NDJSONの1行、snake_case）
```json
{"t":"seg","id":"<uuid>","session":"<id>","seq":123,
 "device":"<device_id>","device_name":"bash iPhone","owner":"小芝","platform":"ios","source":"mic",
 "start":1757600000123,"end":1757600003456,
 "text":"……","confidence":0.92,"level_dbfs":-23.5,
 "speaker":{"local":"s2","embedding":[0.01,...]},
 "clock_offset_ms":-84,"received_at":1757600004000}
```
- `start`/`end`はデバイス時計のepoch ms（capture開始時刻 + sample数/rateで算出、sample精度）。`source`は`mic` / `system` / `watch`
- `speaker.embedding`は話者分離が付けた声の埋め込み（次元は調査結果で確定）。無い場合は`speaker`省略
- `clock_offset_ms` / `received_at`はMacが受信時に付与（Macの自segは0）

### その他のtimed.jsonlレコード
- `{"t":"session","id":..,"started":..,"owner":..}` 先頭1行
- `{"t":"device","device":..,"device_name":..,"owner":..,"offset_ms":..}` 接続ごと
- `{"t":"speaker_name","speaker":"g3","name":"田中"}` 命名・改名（後勝ち）

### 出力ファイル（app設定の保存先ディレクトリ直下、接頭辞は録音開始のローカル日時）
1回の収録（開始〜停止）で次を出す。例: 開始が2026-09-12 14:30:05なら`2026-09-12_143005.*`
- `<start>.live.txt`: **ひたすらリアルタイム**。Mac側でfinalになった本文を1行ずつ追記するだけ。書き換えない（`tail -f`で追える）
- `<start>.timed.jsonl`: **時刻情報付きストリーム**。上記Segment / recordを到着順に追記するsource of truth。iPhone / Watchから後で届いた分もここに追記される。segはfinal結果のみ（volatileは書かない）
- `<start>.final.md`: **完成版**。停止時にReconcilerで全segを統合し話者名を付けて全体を書く（`HH:MM:SS **話者**: 本文`）。停止後にiPhone / Watchの遅延分が届いたら再生成して上書き（`notetaked render`でも手動再生成可）
- `<start>.polished.md`: Foundation Modelsによる整形版（ボタン / `notetaked polish`で任意に生成）
- `<start>.speakers.json`: この収録の話者id → 名前・centroid埋め込み
- 大域プロファイル `~/Library/Application Support/Notetake/speakers.json`: 命名済み話者のcentroid（次回以降の収録で自動一致 = 事実上の声の登録）

収録の対応付け: iPhone / Watchのsegは時刻を持つので、Macは受信時に「その時刻を含む収録」を選んで追記する（進行中の収録が無ければ過去の収録のうち時間範囲に入るもの）。どれにも入らないsegは`orphans.jsonl`へ追記し捨てない

## Reconciler（後追い反映の中核、NotetakeCore、純粋関数）

入力: 全`seg` + `device`のoffset + `speaker_name`。出力: `[Utterance]`（`id`, `start`, `end`, `speaker`, `text`, `sources:[seg id]`）。増分適用も同じ規則で、影響を受けたutteranceのupsertを返す。

1. 時刻正規化: `start + clock_offset_ms`
2. 統合判定: **別デバイス**由来で、時間範囲の重なりが短い方の50%以上（±1.0秒の許容）かつ、正規化文字列（NFKC、句読点・空白除去）の文字bigram Dice係数 ≥ 0.5 → 同一発話。同一デバイス内のsegは統合しない
3. 本文の選択: `confidence`最大 → 同点なら`source`優先度（system > mic > watch）→ さらに同点なら長い方。負けた方は`sources`に残す（polishが参照可）
4. 話者: `SpeakerRegistry`が埋め込みから付けた大域idを優先。埋め込みが無いsegは、統合相手の話者 → なければデバイスownerラベル（systemは「リモート」）
5. 出力は`start`順。utterance idは最初に受信したsegのidで安定させる（ライブパネルのin-place更新に必要）

決定論的なfoldなので、`notetaked render`でtimed.jsonlから常に同じfinal.mdを再生成でき、テストはfixture駆動で書ける。ライブパネルはこのfoldの増分upsertをそのまま表示する。

## 話者分離（Core ML）

### ライブラリ（調査で確定）
- **FluidAudio** `https://github.com/FluidInference/FluidAudio.git`（v0.15.7、Apache-2.0、SPM、macOS 14+ / iOS 17+、swift-tools 6.0）。Python不要でCore ML変換済みモデルを使う
- モデル: Hugging Face `FluidInference/speaker-diarization-coreml`（pyannote segmentation-3.0 + WeSpeaker v2のCore ML版）。`DiarizerModels.downloadIfNeeded()`で初回のみ自動取得、以降オフライン。手動配置も可
- API（ソース確認済みの型名）: `DiarizerModels.downloadIfNeeded()` → `DiarizerManager()` → `initialize(models:)` → `performCompleteDiarization(_ samples: [Float])`（16kHz mono）。結果segmentは時間範囲・speaker id・**256次元L2正規化埋め込み**を持つ。chunk横断の話者id一貫性は`SpeakerManager`が担う（公開signatureは実装時にソースで確認）
- chunk長: 3〜5秒が実用下限、**10秒が最適**（doc記載）。`DiarizerConfig.clusteringThreshold`の推奨例は0.7
- streaming用のLS-EEND / Sortformerも同梱されるが、埋め込みが要る本件はpyannote + WeSpeakerのchunk処理を使う
- モデルライセンスはpyannote segmentation-3.0の記載が情報源で食い違う（MIT / CC-BY-4.0）。自分用の範囲では問題無いが、配布前に本家ページで確認する

### 組み込み
- `NotetakeDiarization` targetがFluidAudioに依存し、`Diarizer` actorとして「16kHz mono floatを受け取り、10秒（設定可）溜まるごとに`performCompleteDiarization`を呼び、stream原点からの絶対時刻に直した話者turn（時間範囲・local id・埋め込み）を返す」だけを提供する。各音声stream（Mac mic / Mac system / iPhone mic）に1インスタンス
- **Aligner**（NotetakeCore、純粋関数）: Transcriberのfinal結果を、runごとの`audioTimeRange`を使って話者turn境界で分割し、各片に最大重なりの話者を割り当てて`seg`にする。分離結果がその時間範囲を覆うまでfinal結果を保留（保留上限 = chunk長 + 2秒、超えたら話者未定で出す）
- **SpeakerRegistry**（NotetakeCore、Macで使用）: 大域話者ごとにcentroid埋め込み（所属segの埋め込みの正規化平均）を持ち、新しい埋め込みをcosine類似度で最近傍に割り当てる。初期閾値0.7（設定可。デバイス横断で同一人物が割れる場合に下げる）。閾値未満なら新規話者「話者N」。デバイス横断・session横断の同一人物統合はこれ一つで担い、命名はライブパネルから。大域プロファイルに命名済み話者のcentroidを保存し、次回sessionでは先にそれと照合する
- ライブパネルは、final直後の本文を暫定話者（デバイス / source）で即表示し、分離結果が付いた時点でutterance upsertにより話者名だけ差し替わる
- iPhoneでも同じ`Diarizer`を動かし、segに埋め込みを載せて送る（M5後半）。Macの`SpeakerRegistry`がMac由来の埋め込みと同じ空間で照合する（同一モデルなので比較可能）

## 後処理 polish（Foundation Models）

- `notetaked polish <start>.timed.jsonl`: timed.jsonl → Reconciler → utterances → 話者turnにまとめ → 1 chunkあたり入力約1500 token（日本語約1500〜2500文字）に分割 → chunkごとに新しい`LanguageModelSession(instructions:)`で「認識誤りの修正・句読点整形・言い淀み除去・意味は変えない・話者ラベル維持」を指示し、`@Generable struct PolishedTurn { speaker: String; text: String }`の配列で受ける → `<start>.polished.md`
- 直前chunkの末尾2 turnを文脈として次chunkの入力に添える（重複出力は時間順で除去）
- 失敗（`exceededContextWindowSize` / guardrail / unavailable）はそのchunkを原文のまま採用し末尾に注記。`SystemLanguageModel.default.availability`を最初に確認
- メニューバーapp / ライブパネルの「整形」ボタンは同じsubcommandを子processで実行

## 通信プロトコル（iPhone→Mac）

- 発見: MacのdaemonがBonjour `_notetake._tcp`で`NWListener`（`includePeerToPeer = true`）。iPhoneは`NWBrowser`で発見し接続
- 認証: TLS PSK。Macのappが表示する6桁ペアリングコードをiPhoneで1回入力しKeychainに保存（LAN上の第三者Macへの誤送信を防ぐsystem boundaryの検証）
- 枠: NDJSON。`hello` → `hello_ack`、`ping`/`pong`（NTP式でMacがoffsetを算出し`device`レコードに記録）、`seg`（`seq`付き）→ `ack {seq}`
- 蓄積転送: iPhoneの`Outbox`（追記ファイル + ack済みseq cursor）。未ackを再接続時にseq順で再送。Mac側は`(device, seq)`で冪等
- Watch→iPhone: `WCSession.transferFile(url, metadata: {session, index, start_at, sample_rate})`。iPhoneはWatchごとの専用Transcriber streamへ`bufferStartTime`付きで順に流し、segの`device`はWatch、`source`は`watch`。転送完了で小片を削除

## Mac daemonの詳細

- 音声: Mic = `AVAudioEngine.inputNode` tap。System = process tap（自processを除外した全体tap）。両方を`AVAudioConverter`でTranscriber形式と16kHz mono float（話者分離用）に変換。bufferごとにRMS(dBFS)を計算しsegの`level_dbfs`へ
- 時刻: capture開始の`Date`を原点に、累積sample数から絶対時刻を算出
- 制御: `notetaked serve --output <dir> --owner <name> --control stdio`（`--output`はappの設定値。単体起動時は必須引数）。stdin: `{"cmd":"start"|"stop"|"rename_speaker"|"polish"|"pair_code"}`。`start`で開始時刻の接頭辞を決めてlive.txt / timed.jsonlを開き、`stop`でfinal.mdを書く。stdout: `{"ev":"status"|"utterance"|"volatile"|"device"|"speaker"|"error",...}`。ログはstderr + `os.Logger`
- 収録外の受信: 停止後に届いたiPhone / Watchのsegは該当収録のtimed.jsonlへ追記し、final.mdを再生成する（daemonは常駐しているので収録中でなくても受け付ける）
- 権限: CLIに`-sectcreate __TEXT __info_plist`でInfo.plist（`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `CFBundleIdentifier`）を埋め込み、Apple Development identityで署名（ad-hoc署名だとビルドごとにTCC再許可になる）。appは子processとして起動する。権限がapp側に帰属するか、CLI自身に帰属するかはM2で実機確認し、どちらでも動く構成にする
- 常駐: appが`Process`で起動し、終了を検知したら再起動（再起動後は同じ接頭辞のlive.txt / timed.jsonlへ追記を続ける）

## Mac appの詳細

- `MenuBarExtra`: 開始/停止、ライブパネルを開く、フォルダを開く、整形、設定
- 設定Window: **保存先ディレクトリ**（`NSOpenPanel`で選択、UserDefaultsに保存。未設定なら開始ボタンを無効化して設定を促す）・自分の名前・ペアリングコード表示。daemon起動時に`--output`として渡す
- ライブパネル（SwiftUI `Window`、常に前面トグルあり）: utterance一覧（時刻・話者名・本文、`.textSelection(.enabled)`）、末尾に認識中のvolatile行、「全文コピー」、話者名クリックで改名、接続デバイスとoutbox残数の表示
- 状態はdaemonのstdout eventをそのままViewModelに反映（utterance idでupsert）

## リポジトリ構成とビルド

```
notetaked/
  Package.swift                # NotetakeCore, NotetakeDiarization, notetaked(executable)
  Sources/NotetakeCore/ Sources/NotetakeDiarization/ Sources/notetaked/
  Tests/NotetakeCoreTests/     # Reconciler / codec / renderer / registry / outbox のfixtureテスト
  Apps/project.yml             # XcodeGen: Notetake(macOS), NotetakeMobile(iOS), NotetakeWatch(watchOS)
  Apps/Notetake/ Apps/NotetakeMobile/ Apps/NotetakeWatch/
  docs/superpowers/specs/ docs/superpowers/plans/
```
- SwiftPMが一次（`swift build` / `swift test` / `swift run notetaked serve`で高速反復）。appはXcodeGenで生成し、Run Script phaseで`swift build -c release --product notetaked`して`Contents/MacOS/notetaked`へ埋め込む
- bundle id: `io.github.bash0c7.notetake`（mac）/ `.notetake.ios` / `.notetake.ios.watchkitapp`。Team `SM5792D355`、自動署名。mac appはsandbox無し（直接配布・自分用）
- Swift 6 strict concurrency。actorで音声pipelineを分離
- 話者分離の依存パッケージ（FluidAudio）はM3で`NotetakeDiarization` targetにのみ追加（watchOSを含む`NotetakeCore`には入れない）

## マイルストーンとtask分割

各taskは「Sonnetが実装（純粋ロジックはTDD）→ Haikuがbuild/test実行 → Fableがレビュー・統合・commit」。意味のある単位ごとにlocal commit。

- **M0 bootstrap**: `git init`、Package.swift、project.yml、空app 3種がビルドできる、`swift test`が1件通る。本計画を`docs/superpowers/specs/2026-09-12-notetake-design.md`として保存
- **M1 NotetakeCore**: Segment/records + NDJSON codec → TranscriptRenderer → Reconciler（統合規則・後追いupsert）→ SpeakerRegistryのcosine clustering → Outbox → clock offset算術。全てfixtureテスト
- **M2 Mac daemon + app**: Transcriber wrapper（asset install、format変換、volatile/final、時間範囲）→ MicCapture → SystemAudioCapture(process tap) → SessionStore → `serve` + stdio制御 → メニューバーapp（daemon監督）→ ライブパネル。ここでTCC帰属を実機確認
- **M3 話者分離（Mac）**: FluidAudio導入と`Diarizer` actor（モデル初回取得の進捗をパネルに出す）→ Aligner（fixtureテスト）→ Registry接続 → speakers.json / 大域プロファイル → パネルの命名UI → 2話者音源で実機確認
- **M4 polish**: chunk分割 → Foundation Models呼び出し → 失敗時fallback → `polish` subcommand → app連携
- **M5 iPhone**: 送信protocol（Mac側listener + PSK + ack + offset）→ iOS app（録音・Transcriber・Outbox・PeerClient・background audio）→ Reconcilerのデバイス横断統合を実機で確認 → iPhone側話者分離と埋め込み送信
- **M6 Watch**: 小片録音・rotate・transferFile → iPhone側受信・専用Transcriber・中継 → 実機確認

M2完了時点でMac単体の製品として使え、M4までで整形も揃う。M5以降は「後追いで精度を上げる」拡張。

## 検証

- 単体: `swift test`（Reconcilerの統合・非統合・後追いupsert、offset補正、renderer、registryの閾値、outboxの再送）
- Mac実機（Claudeが実行可）: `swift run notetaked serve --output <scratch dir> --control stdio`を起動し、`say -v Kyoko "……"`でシステム音声を鳴らして`<start>.live.txt`に本文が即時追記されること、`<start>.timed.jsonl`にsystem由来segが時刻付きで出ること、`stop`で`<start>.final.md`が書かれること、ライブパネルに即時表示されることを確認。話者分離は2話者の日本語音源をシステム音声で再生し、話者数と一貫性を確認
- 遅延反映: iPhoneを機内モードで収録→Mac側停止→機内モード解除で届いた分が`timed.jsonl`に追記され`final.md`が再生成されることを確認
- Macマイク: userが発話して確認（人間にしかできない）
- iPhone / Watch: Claudeが`xcodebuild`で実機向けにビルドし`xcrun devicectl`でインストール・起動。userが発話・移動（オフライン→再接続の蓄積転送）・Watch操作を実施（物理操作）。Mac側でtimed.jsonlのdeviceレコードとoffset、final.mdの統合結果をClaudeが確認
- polish: 上記sessionに対し`notetaked polish`を実行し出力を確認

## リスクと対処

- **子process起動時のTCC帰属（M2で実機確認済み）**: appが`Process`で起動したdaemonのマイク・システム音声録音の許可は**親appのNotetake.appに帰属する**。確認方法: `tccutil reset Microphone/AudioCapture io.github.bash0c7.notetake`でリセット後、appから収録開始すると許可ダイアログがマイク・システム音声で別々に出て、システム設定 > プライバシーとセキュリティ の両欄に「Notetake.app」が並ぶ（2026-09-13、macOS 26.5、ad-hoc署名）。daemon側のbundle id `io.github.bash0c7.notetaked`はLaunchServicesに登録されないため`tccutil reset`は「No such bundle identifier」を返す。対処: appのInfo.plistに`NSMicrophoneUsageDescription`と`NSAudioCaptureUsageDescription`を持たせる（`Apps/project.yml`で設定済み）。daemonに埋め込んだInfo.plistは、terminalから単体起動した場合にterminal appへ帰属する際の説明文として残す
- **話者分離モデルの初回ダウンロード**: Core MLモデルは初回にネット取得が要る可能性 → appに同梱して完全オフライン化する選択肢を調査結果で判断
- **話者分離の遅延**: chunk長ぶん話者名の確定が遅れる。本文は即時表示し話者名だけ後から差し替える設計で吸収
- **Foundation Modelsのguardrail / context超過**: chunk単位のfallbackで原文を残す
- **`SpeechAnalyzer`のリソース上限**: Macで2本 + Core MLは問題無い見込み。超過時は`ignoresResourceLimits`ではなくstream数を減らす
- **時計ずれ**: Apple機は通常100ms以内。ping/pongのoffset補正 + Reconcilerの±1.0秒許容で吸収

## 承認後の進め方

1. M0で`git init`し、本計画を`docs/superpowers/specs/2026-09-12-notetake-design.md`として保存・commit
2. superpowersの`writing-plans`でM0〜M2の詳細実装計画（task単位、TDD手順付き）を`docs/superpowers/plans/`に作成し、`subagent-driven-development`で実行。M3以降は前マイルストーンの実機確認後に同様に計画する
3. 各task: Sonnet subagentが実装、Haiku subagentがbuild / test / xcodegen / devicectlを実行して結果を報告、Fableがレビュー・統合・local commit。push / PRはuser確認後のみ
