# 場所情報（入力機材・方位）と整形の対話化 — 設計

親spec: `2026-09-12-notetake-design.md`（データモデル・Reconciler・polishの基盤）。本specはそれに対する追加・変更で、記述が衝突する箇所は本specが優先する。過去互換は不要（user決定）。

## 目的

- 「誰が、どこから話しているか」を可能な限り残す。空間オーディオ収録に対応した機材ではsegに方位を付け、非対応機材では「どの機材で拾ったか」だけを残す
- 整形（polish）は時刻を捨て、対話のturn列だけを整えて出す。文章としての一貫性を読みやすくするため

## 確認済みの事実（2026-09-13、実機probe）

- Apple の空間オーディオ収録APIは `AVCaptureDeviceInput.multichannelAudioMode = .firstOrderAmbisonics`（macOS 15+/iOS 18+）と `AVCaptureAudioDataOutput.spatialAudioChannelLayoutTag`（macOS 26+/iOS 26+）。対応可否は `AVCaptureDeviceInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics)` で許可なしに即時判定できる
- このMac（MacBook Air M3）に繋がる機材はすべて非対応: 内蔵マイク（stereo=false / FOA=false / 入力1ch）、AirPods Pro 3（同）、Continuity経由のiPhone 13 Pro / 16e（同。ただしこれはブリッジの制限で、iPhone本体のカメラ／マイクAPIの対応可否は別）
- 内蔵マイクは3本あるがOSがビームフォーミング済みの1chとして見せる。生のマルチチャンネルは取れない
- iPhoneのFOA収録はiPhone 16系で提供されている。iPhone 16eが対応かは実機で `isMultichannelAudioModeSupported` を呼んで初めて分かる（証明書再発行後の最初の実機起動で判明）

## user決定事項

- 方向は3（AirPods Pro 3を繋いで再probe）+1（iPhoneを空間マイクにする）。非対応機材は「どの機材か」だけ残す
- 収録開始時に対応可否を判定する
- パネル / final.md の方位表記は時計位置（`2時`）
- 整形は時刻情報なし、対話のみ

## データモデル

### Segment（`timed.jsonl` の `seg`、追加フィールド）

```json
{"t":"seg", ...既存..., 
 "input":{"name":"MacBook Airのマイク","uid":"BuiltInMicrophoneDevice","spatial":false},
 "direction":{"azimuth_deg":57.3,"confidence":0.82}}
```

- `input`（必須）: 音を拾った入力機材。`name` は `AVCaptureDevice.localizedName`、`uid` は `uniqueID`、`spatial` は開始時の `isMultichannelAudioModeSupported(.firstOrderAmbisonics)`。system音声は `{"name":"system","uid":"system","spatial":false}`、Watchは `{"name":"Apple Watch","uid":<Watchのdevice id>,"spatial":false}`
- `direction`（任意）: `input.spatial == true` のsegにのみ付く。非対応はキー自体を出さない
  - `azimuth_deg`: 0以上360未満。収録機材の「上（top edge）」方向を0°、機材を上から見て時計回り。機材は画面を上にして水平に置く前提
  - `confidence`: 0〜1。方位ベクトルの合成長（後述）
- 既存の `device` / `device_name` は「収録したデバイス（Mac / bash iPhone / Watch）」のままで意味を変えない。`input` はそのデバイスに繋がった入力機材で、Macでは内蔵マイクかAirPodsかが変わる

### Utterance（Reconcilerの出力、追加フィールド）

- `input: String` — 採用本文segの `input.name`
- `direction: Direction?` — 統合したsegのうち `direction` を持つものがあれば採用。複数あれば `confidence` 最大。本文の採用（source優先度）とは独立に決める
- 既存の `devices` は据え置き

### 表示用の短縮ラベル（`InputLabel.short(name:platform:source:)`、NotetakeCore、純粋関数）

| 条件 | 表示 |
|---|---|
| source == system | `system` |
| platform == watchos | `Watch` |
| platform == ios | `iPhone` |
| name に "AirPods" を含む | `AirPods` |
| それ以外（Mac内蔵マイク等） | `Mac` |

方位の時計位置（`ClockPosition.label(azimuthDeg:)`、純粋関数）: `round(azimuth / 30) mod 12`、0は12 → `"12時"`〜`"11時"`。

### final.md / live表示

- `TranscriptRenderer`: `HH:mm:ss **話者**（場所）: 本文`。場所は `direction` があれば `iPhone 2時`、無ければ短縮ラベルのみ（`Mac` / `AirPods` / `system` / `Watch`）
- ライブパネル: 話者名の右に小さく灰色で同じ文字列。状態行末尾に `入力: <input.name>（空間: 対応 / 非対応）`。`StatusEvent` に `input_name: String?` と `input_spatial: Bool?` を追加し、daemonが `start` / `rotate` 時の判定結果を入れる（`--source both` ではmic側の値。停止中はnull）

## 方位推定（`DirectionEstimator`、NotetakeCore、純粋計算）

入力: FOA 4ch PCMフレーム（ACN順 / SN3D正規化: ch0=W, ch1=Y, ch2=Z, ch3=X。`kAudioChannelLayoutTag_HOA_ACN_SN3D | 4` の並び）。

- フレームごとに音響インテンシティの水平成分を積分: `Ix = Σ W·X`、`Iy = Σ W·Y`、`E = Σ W·W`
- フレーム方位（数学座標、前=+X、左=+Y、反時計回り）: `θ = atan2(Iy, Ix)`。フレーム信頼度: `c = min(1, sqrt(Ix² + Iy²) / max(E, ε))`。SN3Dの平面波では単一音源で `c ≈ 1`、拡散音で `c ≈ 0`
- seg方位: segの時間範囲に入るフレームの単位ベクトルを `c` で重み付けした円平均。合成ベクトルの長さ（重み和で正規化）を `confidence` とする。`c < 0.2` のフレームは捨てる。有効フレームが無ければ `direction` を付けない
- 出力の `azimuth_deg` は時計回り・上基準に変換: `azimuth_deg = (360 − deg(θ) + azimuthOffsetDeg) mod 360`。`azimuthOffsetDeg` はFOA座標系と機材の「上」がずれていた場合の補正定数（既定0、実機で確認して決める。verification参照）

テスト: 合成FOA（既知方位の平面波 `W=s, X=s·cosθ, Y=s·sinθ, Z=0`）で方位が±2°以内で復元される、拡散音（各chが独立ノイズ）で `confidence` が小さい、円平均が0°/359°境界をまたいでも正しい。

## iPhone側（`Apps/NotetakeMobile/Recorder`）

- 取り込みを `AVAudioEngine` から `AVCaptureSession` + `AVCaptureDeviceInput(builtInMicrophone)` + `AVCaptureAudioDataOutput` に置き換える（対応・非対応で同じ経路にする）
- 開始時: `isMultichannelAudioModeSupported(.firstOrderAmbisonics)` を判定し、trueなら `multichannelAudioMode = .firstOrderAmbisonics` と `spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4`、falseなら `.none`（layout tag は既定のまま）。判定結果を `input.spatial` に、`localizedName` / `uniqueID` を `input` に入れる
- 受け取った `CMSampleBuffer` を `AVAudioPCMBuffer` に変換。FOA時はW chをmonoとして既存Transcriberへ、4ch全体を `DirectionEstimator` へ。非FOA時はそのままTranscriberへ
- segを切るたびに、そのsegの時間範囲のフレームから seg方位を出して `direction` に付ける
- 既存の `PeerMessage.seg` はSegment全体を包むので、プロトコル変更は不要
- Watch由来seg（`WatchRelay`）は `input` を `{"name":"Apple Watch","uid":<Watch device id>,"spatial":false}` に固定

## Mac側（notetaked）

- `MicCapture` は `AVAudioEngine` のまま。`start` / `rotate` 時に `InputDeviceProbe.current()`（`AVCaptureDevice.default(for: .audio)` の `localizedName` / `uniqueID` / `isMultichannelAudioModeSupported`）を取り、そのstreamのsegすべてに同じ `input` を付ける。`SystemAudioCapture` は `system` 固定
- Mac側のFOA取り込み経路は作らない（対応機材が無くテスト不能）。将来対応機材で判定がtrueになった時点でiPhoneと同じ経路を足す。それまでMacの `input.spatial` は常にfalseで `direction` は付かない
- `serve` の `status` に `input_name` / `input_spatial` を入れる
- `orphans.jsonl` / 遅延反映（final.md再生成）は既存の経路がSegment全体を扱うので変更なし

## 整形（polish）の変更

- `PolishChunker.turns(from:)`: 時刻を持たない。`PolishTurn { speaker, text }`。同一話者の連続utteranceを1 turnに結合する既存の挙動は維持
- `PolishedTurn { speaker, text, polished }`（`startMS` を削除）
- `Polisher` に渡す本文から時刻・レベル・input・directionを落とす（chunkは `PolishTurn` の列なので自然に落ちる）。instructionsは「話者ラベル維持・意味を変えない」を維持し、「時刻や場所は扱わない」を明記
- `PolishRenderer.markdown`: 先頭に `# <収録日 yyyy-MM-dd> <参加者名を「、」区切り>`（参加者は登場順の話者ラベル重複なし）、空行、以降 `**話者**: 本文` を1行ずつ。時刻列は出さない。失敗turnの末尾注記は維持
- `notetaked polish` のCLI / app側呼び出し・出力ファイル名（`<prefix>.polished.md`）は変更なし

## 検証

### 自動テスト（NotetakeCore）

- `Segment` / `Utterance` の `input` / `direction` encode-decode（snake_case、`direction` 省略時にキーが出ない）
- `Reconciler`: `direction` 付きsegとMac mic segの統合で `direction` が残る。両方 `direction` 付きなら confidence 最大
- `DirectionEstimator`: 上記3ケース
- `InputLabel.short` / `ClockPosition.label` の表
- `TranscriptRenderer`: 場所付き行の書式
- `PolishChunker` / `PolishRenderer`: 時刻無しturn、見出し、参加者列、同一話者結合、失敗注記

### 実機

- Mac（今すぐ）: `serve` で内蔵マイク→segに `input` が付く。AirPods Pro 3を既定入力にして `rotate` → 新しいprefixのsegの `input.name` がAirPodsになる。final.mdの各行に `（Mac）` / `（AirPods）`。パネルの状態行に入力名と「空間: 非対応」
- iPhone（証明書再発行後）: 初回起動で `input.spatial` の値を確認。trueなら机に平置きし、上端側から `say` を鳴らして `azimuth_deg ≈ 0`、右側から鳴らして `≈ 90` を確認。ずれていれば `azimuthOffsetDeg` を決める。falseなら `direction` 無し・`input.name` のみで、それ以上の作業はしない

## 割り切り・未実装

- 話者ごとの位置の集約（「田中は概ね2時方向」）は保存しない。segの `direction` から導けるため
- Macに空間対応機材が繋がった場合のFOA経路は未実装（判定は出るので気付ける）
- iPhoneが動いた場合（手持ち）の方位は機材基準のままで、世界座標への変換はしない
