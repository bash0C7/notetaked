# 段階Lの検証ゲートと是正 — 設計

親spec: `2026-09-13-spatial-location-polish-design.md`（段階L）。本specは、段階LをMac側で検証した際に見つかった問題の全件と、その根本原因、是正の設計を定める。記述が衝突する箇所は本specが優先する。

## 目的

- 段階L（およびその前提となるM5 / M6）のコードを、Mac上で機械的に検証できる状態にし、検証を通す
- 「検証器を持たない場所で書いたコードを、検証器を通さずに次の工程へ渡す」「出た失敗を1件ずつ潰す」という工程上の原因を、コマンド1本と規律2行で塞ぐ

## 確認済みの事実（2026-09-13、Mac上のビルド・テスト・読み取り専用review）

### A. コンパイル・テストで検出したもの

1. `Tests/NotetakeCoreTests/PolishRendererTests.swift:42`と`TranscriptRendererTests.swift:71`にトップレベル`@Test func emptyIsEmpty()`が重複し、テストtargetがコンパイルできない
2. `DirectionEstimatorTests.swift`の`planeWave`が注記の`[-1, 1)`ではなく`[0, 2)`（平均1の直流成分）を返し、拡散音でもconfidenceが1.0になって2件失敗する。`DirectionEstimator`の数式は親spec通り
3. `Sources/notetaked/Pipeline/CaptureStream.swift:135,146`に不要な`await`の警告2件（前sessionのMac側修正で混入）。HANDOFFは「警告なしが正常」と定める
4. iOSビルド（`NotetakeMobile` scheme）がWatch targetで失敗する。`Apps/NotetakeWatch/WatchRecorder.swift:282`で`ChunkWriter` actorの非async initからactor隔離メソッド`openNextFile()`を同期呼び出ししている
5. `Apps/NotetakeMobile/WatchRelay.swift`の`WatchStream`（可変なfinal class）が`Task<WatchStream, Error>`の結果としてactor境界を越えるため、Sendable違反で6エラー（111 / 189 / 193 / 199行）
6. `Apps/NotetakeMobile/Recorder.swift:73`: `.builtInMicrophone`はiOS 17で`.microphone`に改名済み（警告）
7. `Apps/NotetakeMobile/Recorder.swift:130`: 3と同種の不要な`await`（警告）

`swift build`（Core / daemon）と`make app`（mac Debug、ad-hoc署名）は通る。`swift test`は1・2を除く160件が通る。`Apps/NotetakeMobile`の型検査で、親specが「取り違えやすい」と挙げたApple API（`isMultichannelAudioModeSupported` / `multichannelAudioMode` / `spatialAudioChannelLayoutTag` / `kAudioChannelLayoutTag_HOA_ACN_SN3D` / `CMSampleBufferCopyPCMDataIntoAudioBufferList`）は名前・シグネチャとも通る。

### B. spec照合review（読み取り専用）で検出したもの

8. **バグ**: `Recorder.ingest`が`sampleTime`を変換後（Transcriber入力format）のフレーム数で累積しつつ、`DirectionEstimator.add`へ渡す`startMS` / `endMS`は生マイクのサンプルレートで割って作っている。`Transcriber`は変換後サンプル数を時計にして`piece.startMS`を作るため、両者の時間軸がずれ、`piece`の範囲に該当フレームがほぼ見つからない。親specは「segの時間範囲のフレームから方位を出す」と書くのみで、時刻の基準クロックを定義していない
9. **Macで検証不能**: `foaBuffer(from:)`がHOAタグ付き4chを無タグ4chへ`AVAudioConverter`で変換しており、W / Y / Z / Xの順序が保たれる保証がない
10. **Macで検証不能**: `multichannelAudioMode`を`addInput`後に設定する順序など、実機でしか確かめられない挙動
11. 親spec↔実装の命名ずれ: specは`InputLabel.short(name:platform:source:)` / `ClockPosition.label(azimuthDeg:)`、実装は`LocationLabel.short(inputName:platform:source:)` / `LocationLabel.clock(azimuthDeg:)`。挙動は一致
12. `Recorder.currentInput()`は`start()`前は仮の値を返す。現在の呼び出し順では到達しない

親specのそれ以外の項目（`input` / `direction`のJSON、`Reconciler`の統合規則、`LocationLabel`の表、`TranscriptRenderer`、`StatusEvent`と`ServeSession`、Macパネル、`DirectionEstimator`の数式、`WatchRelay`のWatch入力、polish一式）は実装と一致している。

### C. 工程上の問題

13. iOS / watchOSのコンパイル確認は証明書なしでも`CODE_SIGNING_ALLOWED=NO`で可能なのに、HANDOFFでは段階4・5（実機）の後ろに置かれ、M5 / M6のコードは一度もコンパイルされないまま段階Lが積まれた。4・5はその結果
14. ledger `.superpowers/sdd/2026-09-13-spatial-location-polish/progress.md`はgit管理外で、web側にしか存在しない
15. 前sessionのMac側修正（3）は「警告なし」の基準を確認せずに終えている
16. Mac側の検証で、全体像を取る前に失敗を1件ずつ修正した（1・2・3が未commitの差分として残っている）

## 根本原因

**検証器（コンパイラ・テスト実行・実機）を持たない場所で書いたものを、検証器を通す工程を経ないまま次の工程へ渡し、次の工程では出た失敗を1件ずつ潰した。**

- 1・2・4・5・6・7は、全targetのコンパイルとテストを1回通せば全て出る。Mac側の入口（段階0）が「Coreとdaemonのビルド」だけだったため、iOS / watchOSが入口から外れていた（13）
- 8は、親specが時刻の基準クロックを定めていないことが原因。コンパイルでは捕まらず、時間軸を固定するテストが無かった
- 3・15・16は、修正のたびに「全体の基準（警告ゼロ・全テスト・全target）」に照らし直す工程が無いことが原因

是正はこの3点（入口の検証範囲・時刻基準の定義・修正後の全体照合）を塞ぐ形で行う。

## 検証ゲート `make verify`

`Makefile`に`verify`を追加する。以下を順に実行し、どれか1つでも落ちたら非0で止まる。ログは`.build/logs/`に残す。

1. `swift build`（debug）。出力に`.swift:<行>:<列>: warning:`または`error:`が1行でもあれば失敗。SwiftPMは依存package（FluidAudio）の警告を既定で抑止するため、このgrepは自分のtargetだけを見る
2. `swift test`。失敗0件
3. `make app`（xcodegen + mac Debugビルド、ad-hoc署名）。1と同じregexでコンパイラの`error:` / `warning:`行ゼロ、かつ`BUILD SUCCEEDED`。ファイル位置を持たないツール警告（AppIntents metadata extraction skipped等）は対象外
4. `xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build`。Watch appは埋め込み依存として一緒にビルドされるため、これ1本でiOSとwatchOSの両方を見る。判定は3と同じ

決めごと:

- `-warnings-as-errors`は採らない（依存側の警告を巻き込むため）。grepで判定する
- 実機・証明書が要るものはゲートに入れない。9・10と、WatchのAAC書き出しはHANDOFFの実機検証項に残す
- ゲートの実行はHaiku subagentに委ね、報告形式を「`verify: OK`」または「落ちた段階名 + 該当行の原文」に固定する
- 修正は、ゲートの結果を全件受け取ってから行う。1件ずつ潰さない

## 修正内容

| # | 修正 | 形 |
|---|---|---|
| 1 | `PolishRendererTests.swift`の`emptyIsEmpty`を`polishedMarkdownOfNoTurnsIsEmpty`に改名 | 適用済み（未commit）。トップレベル`@Test`はmodule内で名前空間を共有するため、対象名を含む名前にする |
| 2 | `planeWave`の戻り値を`- 1`して`[-1, 1)`にする | 適用済み（未commit）。実装は触らない |
| 3 | `CaptureStream`の`Task {}`内の同期メソッド呼び出しから`await`を外す | 適用済み（未commit）。actor内で作った`Task {}`は同じ隔離を継承する |
| 4 | `ChunkWriter`: ファイルを開く処理を`private static func openFile(directory:session:index:settings:commonFormat:interleaved:) throws -> (AVAudioFile, URL)`に切り出し、initと`openNextFile()`の両方から使う | 呼び出し側（`WatchRecorder`）は変更なし |
| 5 | `WatchRelay`: `creating`を`[String: Task<Void, Never>]`にし、`buildStream`が完了時に自分で`streams[session]`へ登録して`onStreamCount`を呼ぶ。失敗はその場でlogし登録しない。`streamFor`は生成Taskの完了を待ってから`streams[session]`を読み、nilなら孤児ファイルを消してnilを返す | `WatchStream`はactor内のdictionaryにしか置かれなくなるのでSendable不要。`@unchecked Sendable`は採らない |
| 6 | `.builtInMicrophone`を`.microphone`へ | |
| 7 | `Recorder`の`await self.finish(piece:)`から`await`を外す | 3と同じ理由 |
| 8 | NotetakeCoreに`SampleClock`を追加し、`Recorder.ingest`の時刻計算を変換後サンプル数に統一する（下記） | |
| 9・10 | コード変更なし。HANDOFFの実機検証項に残す | |
| 11 | 親specの命名を実装に合わせる | 親spec改訂 |
| 12 | コード変更なし。親specに「`start()`成功後にのみ有効」と明記 | 親spec改訂 |

### `SampleClock`（NotetakeCore、純粋計算）

```swift
public struct SampleClock: Sendable {
    public let originMS: Int64
    public let sampleRate: Double
    public init(originMS: Int64, sampleRate: Double)
    /// originMS + round(frame / sampleRate * 1000)
    public func ms(atFrame frame: AVAudioFramePosition) -> Int64
}
```

`Transcriber`が`startMS`を作る式（`originMS + round(CMTimeGetSeconds(CMTime(value: sampleTime, timescale: inputFormat.sampleRate)) * 1000)`）と同じ結果になることをテストで固定する。

`Recorder.ingest`は次の順にする。

1. FOA時はW chのmono、非FOA時は取り込みbufferを、`converter`で`transcriber.inputFormat`へ変換する
2. `clock = SampleClock(originMS: originMS, sampleRate: transcriber.inputFormat.sampleRate)`（`start()`でtranscriber生成後に1度作る）で`startMS = clock.ms(atFrame: sampleTime)`、`endMS = clock.ms(atFrame: sampleTime + converted.frameLength)`を求める
3. FOA時は`estimator.add(w:y:x:startMS:endMS:)`
4. `transcriber.feed(converted, at: sampleTime)`、`sampleTime += converted.frameLength`

生マイクのサンプルレートは時刻計算に使わない。Mac側`CaptureStream`は方位を扱わないため変更しない。

## 親spec（段階L）の改訂

- iPhone側の節に「時刻基準」の段落を追加: segの時刻と`DirectionEstimator`へ渡すフレーム時刻は、どちらもTranscriberの入力format（変換後）のサンプル数を`SampleClock`で換算した値。生マイクのサンプルレートは時刻に使わない
- `InputLabel.short(name:platform:source:)`→`LocationLabel.short(inputName:platform:source:)`、`ClockPosition.label(azimuthDeg:)`→`LocationLabel.clock(azimuthDeg:)`（3箇所）。表の下に`LocationLabel.text(inputName:platform:source:direction:)`（短縮ラベルと時計位置の合成、`direction`が無ければ短縮ラベルのみ）を1行追加
- `Recorder.currentInput()`は`start()`成功後にのみ有効、と1行
- 検証節の自動テストに`SampleClock`を追加

## HANDOFFと工程

- **状態**: 当sessionで裏付けた事実に書き換える。Macのbuild / test / appは通過、iOS / watchOSはM6の並行性エラー2群で未通過、段階Lは「実装済み・ゲート未通過」。planの完了時に「`make verify`通過」へ更新する
- **「Mac側で行う検証」**: 段階0を`make verify`に置き換える。段階6末尾の「未実行の検証コマンド」一覧は削除する（ゲートに吸収）。「コンパイルエラーが出やすい箇所」から、コンパイルで確認できた項目（Polisher / PeerListener / Transcriber / Diarizer / RecorderのAPI名）を落とし、実機でしか分からないもの（9・10、WatchのAAC書き出し）だけ残す
- **ledger**: web側のledgerはMacから読めない旨を記し、本specのplanのledgerをMac側で新規に作る
- **規律（project `CLAUDE.md`に2行追加）**: 「修正は`make verify`の結果を全件受け取ってから行う。1件ずつ潰さない」「`make verify`を通していないものをHANDOFFで『実装済み』と書かない（『未検証』と書く）」
- **段階L planのチェックボックス**: 未チェックのMac側実行待ち14項目は、本specのplanの最終タスクでゲート通過をもってチェックする
- **commit粒度**: 本specと親spec改訂で1 commit、planで1 commit、以降はplanのタスクごとに1 commit（trailer付き）

## 検証

### 自動テスト（NotetakeCore）

- `SampleClock.ms(atFrame:)`: 16000Hzで16000フレーム→`originMS + 1000`、8000フレーム→`+500`。丸めが`Transcriber`の式と一致する（同じ入力で同じ値）
- 既存の`DirectionEstimator` 9件（2の修正で通る）、`PolishRenderer` 5件（1の修正で通る）

### ゲート

- `make verify`が`verify: OK`で終わる。これが本specの完了条件

### 実機（証明書再発行後、HANDOFFに残す）

- 9: iPhoneでFOAが`true`の時、上端側から`say`→`azimuth_deg ≈ 0`、右側から→`≈ 90`。ずれていれば`foaBuffer(from:)`を手動de-interleaveへ差し替える（親spec plan Task 7の注記）
- 10: `multichannelAudioMode`の設定順序で`startRunning()`後に4chが来るか
- WatchのAAC書き出し（`AVAudioFile(forWriting:settings:commonFormat:interleaved:)`にAAC settingsでPCMを`write(from:)`）

## 割り切り・未実装

- `-warnings-as-errors`は採らない
- `make verify`はxcodebuildのpackage解決を含むため、Bash sandbox内では止まる可能性がある。sandbox外で実行する（HANDOFFの環境の注意に既記）
- 9・10はMacでは検証できないため、本specの完了条件に含めない
