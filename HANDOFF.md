# HANDOFF — Notetake / notetaked

## 状態（2026-09-13）

- **M0〜M2完了、`main`にmerge済み**（`fa3bc8d`）。Mac単体の製品として動く: メニューバーapp（Notetake.app）がdaemon（notetaked）を子processで起動し、mic + システム音声をリアルタイムに文字起こしして`<保存先>/<yyyy-MM-dd_HHmmss>.live.txt / .timed.jsonl / .final.md`を出す。ライブパネルでコピー・話者改名ができる
- **branch `claude/jolly-fermi-mi44i4`（PRあり）: 「区切る」機能を実装済み・Mac未検証**。Linuxのweb sessionで書いたため`swift test` / `make app`を一度も通していない。**次にやること: 下記「Mac側で行う検証」を上から順に実行し、通ったらPRをmerge**。計画: `docs/superpowers/plans/2026-09-13-rotation.md`
  - daemon: `{"cmd":"rotate"}`（収録中にstop→startをactor内で一括。中間の停止statusは出さず新prefixの`status`と`log`を出す。同じ秒のprefixになる場合は開始日時を1秒進める）
  - app: メニュー「収録を区切る」、ライブパネルに「収録開始」「収録停止」「区切る」、設定「自動で区切る間隔」（時間・小数可、既定24、0で区切らない。UserDefaults `rotationIntervalHours`）。タイマーはapp側（`AppModel.scheduleRotation()`、`ContinuousClock`なのでMacスリープ中も進む）。状態行に「次の区切り」
  - 長時間収録: `Transcriber.fedFrames`をUInt64に、`CaptureStream.levels`を直近2分で刈る
- その後: M3以降の計画の検討（下記「次フェーズの検討」）

## Mac側で行う検証（branch `claude/jolly-fermi-mi44i4`）

1. `make test` → 全件通る（M2時点49件 + `MessagesTests`のrotate + `RotationScheduleTests`）。落ちたらまずtest側の期待値ではなく実装を疑う（testが仕様）
2. `swift build 2>&1 | grep -i warning` → 出力なし
3. CLI e2e（rotateで2つのprefixができ、各final.mdに該当発話が入る）:
   ```bash
   make daemon && rm -rf /tmp/nt && mkdir -p /tmp/nt
   ( sleep 3; say -v Kyoko "一つ目の収録です。"; sleep 12; say -v Kyoko "二つ目の収録です。" ) &
   ( sleep 12; echo '{"cmd":"rotate"}'; sleep 14; echo '{"cmd":"stop"}'; sleep 2; echo '{"cmd":"quit"}' ) \
     | .build/release/notetaked serve --output /tmp/nt --owner 小芝 --source system --start | tee /tmp/nt/events.log
   ls /tmp/nt/*.final.md            # 2件
   grep -c '"ev":"status"' /tmp/nt/events.log   # 4（起動時false / --startのtrue / rotateのtrue / stopのfalse）
   grep '"ev":"log"' /tmp/nt/events.log         # rotated <old> -> <new>
   ```
4. `make app` → ライブパネルに 収録開始 / 収録停止 / 区切る。開始→`say`→区切る→`say`→停止 で保存先に2組のファイル。区切った瞬間にパネルの一覧がクリアされ状態行のprefixが変わる（userの画面確認）
5. 設定「自動で区切る間隔」に`0.05`（3分）を入れて収録開始 → 状態行に「次の区切り HH:mm」→ 3分後に自動で区切られ、さらに3分後にもう一度。`0`にすると「次の区切り」が消え自動区切りが止まる。最後に`24`へ戻す
6. 設定Windowで名前欄にfocusしたまま閉じても値が保持される（`onDisappear`でcommit）

## ドキュメント

- 設計spec（M0〜M6の全体設計、binding authority）: `docs/superpowers/specs/2026-09-12-notetake-design.md`
- M0〜M2の実装計画（完了。Task構成・interface・検証コマンドの記録として参照）: `docs/superpowers/plans/2026-09-12-m0-m2-mac-core.md`
- 「区切る」機能の実装計画（実装済み・Mac検証待ち）: `docs/superpowers/plans/2026-09-13-rotation.md`
- project instructions（モデル分担・SDDの手順・署名の注意）: `CLAUDE.md`

## いま動くもの（使い方）

- app: `make app` → `.build/DerivedData/Build/Products/Debug/Notetake.app`。設定Windowで保存先と自分の名前を指定（UserDefaults `io.github.bash0c7.notetake` の `outputDirectory` / `ownerName`）。daemonは`serve --output <dir> --owner <name> --source both --control stdio`で起動される
- CLI: `make daemon` → `.build/release/notetaked`。subcommand: `serve`（stdin `{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"quit"}`、stdout `{"ev":"status"|"utterance"|"volatile"|"error"|"log",...}`）/ `render <timed.jsonl>` / `transcribe <audio file>` / `capture --source mic|system --seconds N`
- e2e（system音声のみ）:
  ```bash
  make daemon && rm -rf /tmp/nt && mkdir -p /tmp/nt
  ( sleep 3; say -v Kyoko "明日の会議は十時からです。" ) &
  ( sleep 12; echo '{"cmd":"stop"}'; sleep 2; echo '{"cmd":"quit"}' ) | .build/release/notetaked serve --output /tmp/nt --owner 小芝 --source system --start
  cat /tmp/nt/*.final.md
  ```

## 次フェーズの検討（着手前に`superpowers:brainstorming`→`writing-plans`→`subagent-driven-development`）

specのマイルストーン順は M3 話者分離 → M4 polish → M5 iPhone → M6 Watch。検討時の論点:

- **M3 話者分離（Mac）**: FluidAudio v0.15.7（`https://github.com/FluidInference/FluidAudio.git`、Apache-2.0、SPM）を`NotetakeDiarization` targetにのみ追加。モデル`FluidInference/speaker-diarization-coreml`は初回にHugging Faceから取得（オフライン化のためapp同梱にするかを決める）。`Diarizer` actor（16kHz mono、10秒chunk、閾値0.7、256次元埋め込み）→ `Aligner`（final結果を話者turn境界で分割、保留上限chunk長+2秒）→ `SpeakerRegistry`（cosine最近傍、閾値0.7、命名済みcentroidを`~/Library/Application Support/Notetake/speakers.json`に永続化）→ `<prefix>.speakers.json` → パネルの命名UI。実機確認は2話者の日本語音源をsystem音声で再生
- **M4 polish**: Foundation Models（`SystemLanguageModel.default.availability`を最初に確認、sessionあたり4096 token）。turn単位で約1500 token chunk、`@Generable struct PolishedTurn`、失敗chunkは原文採用、`notetaked polish <timed.jsonl>` → `<prefix>.polished.md`。appの「整形」ボタンは子processで同subcommand
- **M5 iPhone**: Bonjour `_notetake._tcp` + `NWListener(includePeerToPeer)`、TLS PSK（appが表示する6桁コード）、NDJSON `hello`/`ping`/`seg`/`ack`、iPhone側`Outbox`（未ack再送、`(device, seq)`で冪等）、Macの`clock_offset_ms`付与とReconcilerのデバイス横断統合。**Apple Development証明書の再発行が前提**（下記）
- **M6 Watch**: 前面録音→20秒AAC小片→`WCSession.transferFile`→iPhoneの専用Transcriber stream。`NotetakeWatch` targetは現状`NotetakeCore`に依存していない（M6で追加し、watchOSでCoreがコンパイルできることを初めて確認する）
- **横断**: 停止後に届いたiPhone／Watchのsegを該当収録のtimed.jsonlへ追記しfinal.mdを再生成する経路（spec「収録の対応付け」「orphans.jsonl」）はM5で実装。daemon再起動後に同じ接頭辞で収録を再開する要件（spec）は未実装で、M3〜M5のどこで拾うか決める

## M0〜M2の最終reviewで持ち越した項目（次の計画で扱うか判断する）

- CaptureStream: `AVAudioConverter.convert`をIOProc（real-time thread）で実行し、失敗を`try?`で捨てている → `ingest`側（actor）へ移してEvent.errorで報告
- CaptureStream: system最初のsegの`level_dbfs`が-120になる（pieceの時間範囲にbufferが無い時のfallback）。無音時の`levels`増加はrotation branchで時間刈りを入れた
- ServeSession: capture開始失敗時に`session`/`device`だけの`timed.jsonl`が残る
- DaemonClient: stdout chunkごとのTask hopがFIFO前提 → AsyncStreamで直列化
- SettingsView: focusしたまま閉じると編集が落ちる件はrotation branchで`onDisappear`commitを入れた（Mac側検証6で確認）
- 録音中に設定（名前・保存先）を変えた場合の`restartPending`再起動は、区切り（`rotate`）では適用されず次の明示的な停止まで持ち越す（rotateは中間の停止statusを出さないため）
- Transcriber: 変換ごとの`AudioConverter.reset()`が認識品質に与える影響をM3前にA/B（`fedFrames`のUInt64化はrotation branchで実施）
- LivePanel: 「常に前面」toggleはwindowを開き直すと初期値に戻る（userは「だいじょうぶ」と判断）
- spec追記候補: `--source both`でヘッドホン無しの場合、リモート音声がmicとtapの両方に入り、同一deviceなので統合されず重複する

## 環境の注意

- **Apple Development証明書が失効中**（`spctl`: `CSSMERR_TP_CERT_REVOKED`）。daemonとmac appはad-hoc署名（`Makefile`の`DAEMON_IDENTITY ?= -`、`Apps/project.yml`のmac targetは`CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "-"`）。**user作業**: Xcode > Settings > Accounts > Manage Certificates で再発行（M5のiPhone実機ビルドまでに必須）。再発行後は`DAEMON_IDENTITY=<SHA-1>`を渡し、project.ymlの署名設定を`Automatic` + Team `SM5792D355`へ戻す
- **TCC帰属（M2で実測）**: appが子processで起動したdaemonのマイク／システム音声録音の許可は親app（Notetake.app）に帰属する。usage stringはappのInfo.plist（project.yml）に必要。daemonの`io.github.bash0c7.notetaked`はLaunchServices未登録で`tccutil reset`は効かない。terminalから単体起動した場合はterminal appに帰属。ad-hoc署名でrebuildした後に再許可が要るかは未確認
- **system音声tapの特性**: 音を出しているprocessが無い間はbufferが1つも来ない（無音のまま停止しても`Transcriber.finish()`は入力0の高速経路で戻る）
- git push / ghはBash sandboxでは資格情報が読めない → sandboxを無効にして実行。sandbox内で`~/.gitconfig`が読めない時は`GIT_CONFIG_GLOBAL=/dev/null`（repo localにuser.name/email設定済み）
- ja-JP音声モデルはダウンロード済み。日本語TTS voiceはKyoko / Otoya

## 検証コマンド

- `make test` / `make daemon` / `make project` / `make app`
- `swift build 2>&1 | grep -i warning`（出力なしが正常）

## GitHub

- public repo: https://github.com/bash0C7/notetaked（default `main`）
