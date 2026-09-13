# HANDOFF — Notetake / notetaked

## 状態（2026-09-13）

- **M0〜M2完了、`main`にmerge済み**（`fa3bc8d`）。Mac単体の製品として動く（メニューバーapp + daemon、mic + system音声のリアルタイム文字起こし、`<prefix>.live.txt / .timed.jsonl / .final.md`、ライブパネル）
- **branch `claude/jolly-fermi-mi44i4`（draft PR https://github.com/bash0C7/notetaked/pull/1）: 「区切る」機能 + M3〜M6を実装済み。Macで`swift build` / `make app`が通り、Notetake.app（新daemon同梱）が起動・userが動作OKを確認済み**（2026-09-13）。**`make verify`通過**（2026-09-13: `swift build`警告ゼロ / テスト164件 / mac app / iOS + watchOSコンパイル）。下記「Mac側で行う検証」の段階1〜6（実機・手動）は未実施
- **段階L（場所情報・対話整形）実装済み・`make verify`通過**（2026-09-13）。segの`input`/`direction`、`LocationLabel`、`DirectionEstimator`、iPhone `AVCaptureSession`+FOA、状態行/パネルの場所表示、polishの時刻無し対話出力。iPhoneの実機検証（`input.spatial`の値、方位、FOA変換のチャンネル順）は証明書再発行後。spec `docs/superpowers/specs/2026-09-13-spatial-location-polish-design.md`、plan `docs/superpowers/plans/2026-09-13-spatial-location-polish.md`。段階LのMac側検証で見つかった問題の全件・根本原因・是正はspec `docs/superpowers/specs/2026-09-13-stage-l-verification-remediation-design.md`、plan `docs/superpowers/plans/2026-09-13-stage-l-verification-remediation.md`。web側のledger（`.superpowers/sdd/2026-09-13-spatial-location-polish/`）はMacからは読めない。Mac側のledgerは`.superpowers/sdd/2026-09-13-stage-l-verification-remediation/progress.md`（git管理外）
- **次: 下記「Mac側で行う検証」の段階1〜6（実機・手動）を順に実行**し、段階ごとにcommit。実機（iPhone / Watch）は証明書再発行が前提

### branchに入っているもの（段階順 = 検証順）

| 段階 | 内容 | 計画doc |
|---|---|---|
| R 区切る | daemon `rotate`、パネルの開始/停止/区切る、設定「自動で区切る間隔」（既定24時間、0で無停止、app側タイマー）、`fedFrames` UInt64、`levels`時間刈り | `docs/superpowers/plans/2026-09-13-rotation.md` |
| M3 話者分離 | FluidAudio 0.15.7（`NotetakeDiarization`）、`Diarizer` actor、`Aligner`（final pieceを分離結果が覆うまで保留、上限12秒）、`SpeakerRegistry`（cosine 0.7、`g<N>`）、`<prefix>.speakers.json`、大域`~/Library/Application Support/Notetake/speakers.json`、`serve --diarize/--no-diarize`、モデル取得進捗を`log`イベント | `docs/superpowers/plans/2026-09-13-m3-diarization.md` |
| M4 polish | `notetaked polish <timed.jsonl>`（Foundation Models、2000文字chunk、失敗chunkは原文）、`<prefix>.polished.md`、app「直前の収録を整形」/ パネル「整形」 | `docs/superpowers/plans/2026-09-13-m4-polish.md` |
| M5 iPhone | `PeerMessage`（hello/hello_ack/ping/pong/seg/ack）、`ClockOffset`、`SessionMatcher`、`Outbox`、daemon `PeerListener`（Bonjour `_notetake._tcp` + TLS PSK）、`pair_code` command / `peer` event、停止後segのfinal.md再生成、`orphans.jsonl`、Mac設定のペアリングコード、iOS app（Recorder / PeerClient / UI） | `docs/superpowers/plans/2026-09-13-m5-iphone.md` |
| M6 Watch | `WatchChunkMetadata` / `WatchChunkSequencer`、Watch app（20秒AAC小片→`transferFile`）、iPhone `WatchRelay`（小片→専用Transcriber→seg→Outbox） | `docs/superpowers/plans/2026-09-13-m6-watch.md` |
| L 場所情報 / 対話整形 | `make verify`通過。segの`input` / `direction`、`LocationLabel`、`DirectionEstimator`、iPhone `AVCaptureSession` + FOA、状態行とパネルの場所表示、polishの時刻無し対話出力 | `docs/superpowers/plans/2026-09-13-spatial-location-polish.md` |
| V 検証ゲート | `make verify`、`ChunkWriter` init / `WatchRecorder`のbuffer受け渡し / `WatchRelay`の並行性修正、`SampleClock`（iPhone側の時刻基準） | `docs/superpowers/plans/2026-09-13-stage-l-verification-remediation.md` |

## Mac側で行う検証（branch `claude/jolly-fermi-mi44i4`、上から順に）

原則: **落ちたらまずテストの期待値ではなく実装を疑う（テストが仕様）**。修正はゲート（`make verify`）の結果を全件受け取ってから行い、1件ずつ潰さない。段階ごとに`git commit`（trailer付き）。

### 0. 依存解決とビルド

```bash
swift package --disable-keychain --disable-netrc resolve   # 初回のみ。FluidAudio 0.15.7のbinaryTarget取得にネット必須
make verify   # swift build（警告ゼロ）→ swift test → make app → iOS + watchOSコンパイル（CODE_SIGNING_ALLOWED=NO）。最終行 verify: OK
```

`make verify`は全targetのコンパイルと全テストを機械的に見る。ログは`.build/logs/verify-*.log`。

**実機でしか分からない箇所**（コンパイルは通っている）:
- `Apps/NotetakeWatch/WatchRecorder.swift`: `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`にAAC settingsでPCMを`write(from:)`できるか
- `Apps/NotetakeMobile/Recorder.swift`: `foaBuffer(from:)`がHOAタグ付き4chを無タグ4chへ`AVAudioConverter`で変換した時にW / Y / Z / Xの順序が保たれるか（崩れていれば手動de-interleaveへ差し替える。段階L plan Task 7 Step 1の「注意」参照）、`multichannelAudioMode`を`addInput`後に設定する順序で`startRunning()`後に4chが来るか

### 1. 区切る（R）

1. CLI e2e（rotateで2つのprefixができ、各final.mdに該当発話が入る）:
   ```bash
   make daemon && rm -rf /tmp/nt && mkdir -p /tmp/nt
   ( sleep 3; say -v Kyoko "一つ目の収録です。"; sleep 12; say -v Kyoko "二つ目の収録です。" ) &
   ( sleep 12; echo '{"cmd":"rotate"}'; sleep 14; echo '{"cmd":"stop"}'; sleep 2; echo '{"cmd":"quit"}' ) \
     | .build/release/notetaked serve --output /tmp/nt --owner 小芝 --source system --start --no-diarize | tee /tmp/nt/events.log
   ls /tmp/nt/*.final.md            # 2件
   grep -c '"ev":"status"' /tmp/nt/events.log   # 4（起動時false / --startのtrue / rotateのtrue / stopのfalse）
   grep '"ev":"log"' /tmp/nt/events.log         # rotated <old> -> <new>
   ```
2. `make app` → ライブパネルに 収録開始 / 収録停止 / 区切る / 整形。開始→`say`→区切る→`say`→停止 で保存先に2組。区切った瞬間にパネルがクリアされ状態行のprefixが変わる（userの画面確認）
3. 設定「自動で区切る間隔」に`0.05`（3分）→ 状態行に「次の区切り HH:mm」→ 3分後に自動で区切られ、さらに3分後にもう一度。`0`で「次の区切り」が消える。最後に`24`へ戻す
4. 設定Windowで名前欄にfocusしたまま閉じても値が残る

### 2. 話者分離（M3）

1. 初回: `serve`（`--diarize`既定on）起動時にHugging Faceから`FluidInference/speaker-diarization-coreml`を取得する（`~/Library/Application Support/FluidAudio/Models/`）。stdoutに`{"ev":"log","message":"diarizer models: N0%"}`〜`diarizer ready`。取得失敗時は`error: diarizer unavailable`を出して分離なしで続行する
2. 上記1のe2eを`--no-diarize`無しで実行し、segに`"speaker":{"local":..,"global":"g1","embedding":[...256]}`が付く、`<prefix>.speakers.json`が書かれる
3. 2話者: 日本語2話者の音源（例: `say -v Kyoko`と`say -v Otoya`を交互に）をsystem音声で再生 → final.mdに`**g1**:` / `**g2**:`が分かれる。ライブパネルで話者名クリック→命名 → 以後の行が名前に変わり、`~/Library/Application Support/Notetake/speakers.json`に命名済みcentroidが残る。**次のserve起動（app再起動）で同じ声に同じ名前が付く**
4. 分離ありでは本文が最大約12秒遅れて出る（volatile行で途中経過は見える）。遅延が許容できるかuser判断。CoreML推論は`CaptureStream.ingest`（feed task）内で同期実行しているため、10秒ごとにtranscriberへのfeedが推論時間ぶん遅れる。問題があれば`Diarizer.feed`を`Task.detached`に逃がす
5. `--source both`でmicとsystemは別`Diarizer`（別local id空間）。同一人物のcentroidが`SpeakerRegistry`（閾値0.7）で束なるか確認。割れるなら`SpeakerRegistry.Config.threshold`を下げる

### 3. polish（M4）

1. Apple Intelligenceが有効なMacで `.build/release/notetaked polish /tmp/nt/<prefix>.timed.jsonl` → stderrに`polish: chunk 1/N`、`<prefix>.polished.md`。無効なら`Foundation Models unavailable: <reason>`で非0 exit
2. appのメニュー「直前の収録を整形」/ パネル「整形」（停止または区切り後に有効）→ メニューに「整形完了: <prefix>.polished.md」
3. 失敗chunkがあれば末尾に`> 整形に失敗したturn: N件（原文のまま）`

### 4. iPhone（M5）— **Apple Development証明書の再発行が前提**

1. Mac: 設定Windowに6桁ペアリングコード（「再生成」可）。app起動後にdaemonへ`pair_code`が送られ、daemonが`_notetake._tcp`をadvertiseする（`dns-sd -B _notetake._tcp`で見える）。CLI単体なら`serve --pair-code 123456`
2. iPhone: `make project` → Xcodeで`NotetakeMobile`を実機へ（`xcodebuild -scheme NotetakeMobile -destination 'id=<udid>'` + `xcrun devicectl device install app`）。初回にローカルネットワーク許可とマイク許可
3. iPhoneでコードを入力→保存 → 状態が「接続: <Mac名>」、Macのライブパネル状態行に「接続: <iPhone名>」
4. Macで収録開始 → iPhoneで開始 → userが発話 → Macのtimed.jsonlに`"platform":"ios"`のsegと`"t":"device"`（`offset_ms`はping/pongの推定）。final.mdでmic/iPhoneの同一発話が統合される（Reconcilerの±1秒・Dice 0.5）
5. 遅延反映: iPhoneを機内モードで収録→Mac側停止→機内モード解除 → 未ack segが再送され、該当収録の`timed.jsonl`に追記・`final.md`再生成（`log: appended peer seg to <prefix>, final.md regenerated`）。どの収録にも入らない場合は`<output>/orphans.jsonl`
6. 冪等: Macの`~/Library/Application Support/Notetake/received/<device>.cursor`。iPhoneを再起動して同じsegを再送しても二重に入らない
7. iPhone側の話者分離（埋め込み送信）は未実装（specのM5後半）。`NotetakeDiarization`はiOS 17+対応なので、Macと同じ`Diarizer`を`Recorder`に足す

### 5. Watch（M6）

1. `NotetakeWatch`を実機へ。前面で開始 → 20秒ごとに`chunks/<session>-<index>.m4a`が`transferFile`される（未転送数がUIに出る）
2. iPhone側`WatchRelay`が受信 → 専用Transcriber → `"platform":"watchos","source":"watch"`のseg → Outbox → Mac。Watchの録音停止後60秒で該当streamを`finish()`
3. Macのfinal.mdでWatch由来segがmic/iPhoneと統合される（source優先度 system > mic > watch）
4. 未確認事項: watchOSの`inputNode`のフォーマットとAAC書き出し、`WCSession`の背景転送、`AVAudioFile(forReading:)`でのAAC→PCM（`processingFormat`）

### 6. 場所情報 / 対話整形（L）

1. Mac: 収録開始→発話→停止。`timed.jsonl` の seg に `"input":{"name":"MacBook Airのマイク","uid":"BuiltInMicrophoneDevice","spatial":false}`、final.md の行が `**話者**（Mac）:`。パネル状態行に `入力: MacBook Airのマイク（空間: 非対応）`
2. AirPods Pro 3 を接続して既定入力にし「区切る」→ 新しいprefixのsegが `"name":"ゆふAirPods Pro 3"`、行が `（AirPods）`
3. `notetaked polish <prefix>.timed.jsonl` → 先頭 `# yyyy-MM-dd 参加者`、行に時刻無し
4. iPhone（証明書後）: 初回起動で `input.spatial` を確認。true なら机に平置きし、上端側から `say` → `azimuth_deg ≈ 0`、右側から → `≈ 90`。ずれていれば `Recorder` の `DirectionEstimator(azimuthOffsetDeg:)` を決める。false なら `direction` 無し・`input.name` のみで完了

## 申し送り（Mac必須・user作業を含む）

- **Apple Development証明書が失効中**（`spctl`: `CSSMERR_TP_CERT_REVOKED`）。daemon / mac appはad-hoc署名（`Makefile`の`DAEMON_IDENTITY ?= -`、`Apps/project.yml`のmac targetは`CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "-"`）。**user作業**: Xcode > Settings > Accounts > Manage Certificates で再発行。再発行後は`DAEMON_IDENTITY=<SHA-1>`を渡し、project.ymlの署名設定を`Automatic` + Team `SM5792D355`へ戻す。iPhone / Watch実機ビルドに必須
- **TCC**: ad-hoc署名でrebuildすると再許可が要る可能性（未確認）。appが子processで起動したdaemonのマイク／システム音声許可は親app（Notetake.app）に帰属。`tccutil reset Microphone/AudioCapture io.github.bash0c7.notetake`でリセット可
- **`swift package resolve`のbinaryTarget取得はkeychain照会で落ちる**（`Failed to find credentials for 'https://github.com' in keychain: status -128`）。`swift package --disable-keychain --disable-netrc resolve`で回避。Bash sandbox内ではgit cloneが途中で止まるためsandbox外で実行
- **ネットワークが要る初回処理**: FluidAudioモデル（Hugging Face）、`swift package resolve`のbinaryTarget（GitHub releases）、ja-JP音声モデル（済み）。オフライン化（モデルのapp同梱）は未対応
- **Foundation Models**: Apple Intelligence有効なM3 Mac。sessionあたり4096 token。`--max-characters`でchunkを小さくできる
- **FluidAudioの推論負荷**: 2 stream同時（mic + system）でのCPU/メモリを`make app`後にアクティビティモニタで確認。10秒chunkごとに数百ms想定
- **iPhone / Watch**: 実機はuserの操作（発話・機内モード・Watch画面操作）が必要。Claudeは`xcodebuild` / `devicectl`でインストール・起動し、Mac側のtimed.jsonl / final.mdを確認する
- **PRの粒度**: 1本のbranch（この session の指定branch）にR〜M6を積んである。段階ごとに切り出したければ`git rebase -i`でcommit範囲ごとにbranchを作る（commitは段階順に並んでいる）

## 設計上の割り切り・既知の未実装

- 区切り（`rotate`）は中間の停止statusを出さないため、録音中に変えた設定（名前・保存先）の`restartPending`再起動は次の明示的な停止まで持ち越す
- 話者分離: specの「本文を即表示して後から話者だけ差し替え」は採らず、`Aligner`で最大12秒保留してから話者付きで出す（timed.jsonlにはfinalだけ書く原則を保つため）
- `SpeakerRegistry`は1回のserve起動の間だけ`g<N>`を保持。命名していない話者はserve再起動で`g1`から振り直し（命名済みは大域プロファイルで引き継ぐ）
- `levelForPiece`: pieceの時間範囲にbufferが無い時のfallback `-120`は未対応
- daemon再起動後に同じ接頭辞で収録を再開する要件（spec）は未実装
- `DaemonClient`: stdout chunkごとのTask hopがFIFO前提 → AsyncStreamで直列化（未対応）
- Transcriber: 変換ごとの`AudioConverter.reset()`が認識品質に与える影響のA/B未実施
- `--source both`でヘッドホン無しの場合、リモート音声がmicとtapの両方に入り、同一deviceなので統合されず重複する（spec追記候補）
- iPhone側の話者分離・埋め込み送信、Watchのownerを`WCSession.applicationContext`で同期、`hello`のowner名変更の即時反映は未実装

## ドキュメント

- 設計spec（M0〜M6の全体設計、binding authority）: `docs/superpowers/specs/2026-09-12-notetake-design.md`
- 実装計画: `docs/superpowers/plans/2026-09-12-m0-m2-mac-core.md`（完了）/ `2026-09-13-rotation.md` / `2026-09-13-m3-diarization.md` / `2026-09-13-m4-polish.md` / `2026-09-13-m5-iphone.md` / `2026-09-13-m6-watch.md`（いずれも`make verify`通過・実機検証待ち）
- project instructions（モデル分担・SDDの手順・署名の注意）: `CLAUDE.md`

## いま動くもの（使い方）

- app: `make app` → `.build/DerivedData/Build/Products/Debug/Notetake.app`。設定Windowで保存先・自分の名前・自動で区切る間隔・ペアリングコード（UserDefaults `io.github.bash0c7.notetake` の `outputDirectory` / `ownerName` / `rotationIntervalHours` / `pairingCode`）。daemonは`serve --output <dir> --owner <name> --source both --control stdio`で起動され、起動直後に`pair_code`を受け取る
- CLI: `make daemon` → `.build/release/notetaked`。subcommand: `serve`（stdin `{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdout `{"ev":"status"|"utterance"|"volatile"|"peer"|"error"|"log",...}`、`--diarize/--no-diarize`、`--pair-code`）/ `render <timed.jsonl>` / `polish <timed.jsonl>` / `transcribe <audio file>` / `capture --source mic|system --seconds N`
- 出力: `<prefix>.live.txt` / `.timed.jsonl` / `.final.md` / `.speakers.json` / `.polished.md`、`orphans.jsonl`

## 環境の注意

- git push / ghはBash sandboxでは資格情報が読めない → sandboxを無効にして実行。sandbox内で`~/.gitconfig`が読めない時は`GIT_CONFIG_GLOBAL=/dev/null`（repo localにuser.name/email設定済み）
- `make verify`はxcodebuildのpackage解決を含むため、DerivedDataにpackageが無い初回はBash sandbox内で止まることがある → sandbox外で実行。2回目以降はsandbox内で通る
- system音声tapの特性: 音を出しているprocessが無い間はbufferが1つも来ない（無音のまま停止しても`Transcriber.finish()`は入力0の高速経路で戻る）
- ja-JP音声モデルはダウンロード済み。日本語TTS voiceはKyoko / Otoya
- 実機probe（2026-09-13）: Macに繋がる機材（内蔵マイク / AirPods Pro 3 / ContinuityのiPhone）はいずれも`isMultichannelAudioModeSupported(.firstOrderAmbisonics)`がfalse、入力1ch。空間収録はiPhone本体でのみ試せる（iPhone 16eの対応可否は実機で判定）
- `make app`で`.build/release/notetaked`を更新してもbundle内が古いままの場合は`Apps/project.yml`のEmbed scriptの`inputFiles`を確認（16d68b1で追加済み）
- Claude Code on the web（Linux）にはSwiftツールチェーンが無く、swift.orgもproxyで403。Swiftの実行が要る作業はMac側セッションで

## 検証コマンド

- `make verify`（ゲート。全targetのビルド警告ゼロ・全テスト・mac app・iOS + watchOSコンパイル。最終行`verify: OK`）
- `make test` / `make daemon` / `make project` / `make app`
- `swift build 2>&1 | grep -i warning`（出力なしが正常）

## GitHub

- public repo: https://github.com/bash0C7/notetaked（default `main`）
- draft PR: https://github.com/bash0C7/notetaked/pull/1（branch `claude/jolly-fermi-mi44i4`）
