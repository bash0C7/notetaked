---
name: daemon-realtest
description: notetaked/capture-daemonのクラッシュ・ハング・resumeをCLIで実機検証する（GUI appを起動せず、userの稼働中Notetake.appに干渉しない）。kill -9・heartbeat確認・checkpoint resumeの手順
---

# daemon-realtest — daemon crash/resume の実機検証（CLI駆動）

**原則**: 実機検証はclaudeが自律的に行う。userに残すのは物理操作（AirPods抜き差し等）とUI体験の主観評価のみ。チェックリストをuserに丸投げしない。

## 事前チェック（必須・毎回）

userの本番Notetake.appが稼働中の前提で作業する。**絶対にkillしない・GUI appを2重起動しない**（`io.github.bash0c7.notetake`のUserDefaultsを共有するため、2重起動は本番設定を壊しうる）。

```bash
ps aux | grep -i notetake | grep -v grep
```
既存プロセスのバイナリpathを確認し、これから自分が起動するworktreeのCLIバイナリと別物であることを確認してから進める。

## ビルド

GUI app（`make app`）ではなくCLIのrelease binaryを使う（bundle ID衝突を避けるため）:
```bash
swift build -c release
```
バイナリ: `<worktree>/.build/release/notetaked`

## 固定パス（worktree外・マシン全体で共有、複数worktree/複数セッションで衝突しうる）

- heartbeat / control channel: `~/Library/Application Support/Notetake/state/{process.heartbeat,capture.heartbeat,capture-command.json,capture-event.json,current-session.json}`
- 生音声buffer: `$TMPDIR/notetake-capture/<prefix>/{mic,system}.{raw,checkpoint}`（`$TMPDIR`はNSTemporaryDirectory()の実体、`/var/folders/.../T/`。`echo $TMPDIR`で確認）

これらは前回テストの残骸が残ることがある。**必ずmtimeを見てから「新鮮」と判断する**（`stat -f "%Sm %N" <path>`）。worktree isolationのあるsessionではパスにスペースを含むコマンドは1コマンド1操作で単純に書く（`cd && ls`のような連結は「too complex」で弾かれることがある）。

## 検証1: notetaked serveのcrash → 自動resume（checkpoint正しさ）

1. capture-daemonを起動（バックグラウンド）: `.build/release/notetaked capture-daemon &`
2. heartbeatが更新され始めることを確認（`cat`→数秒待って再`cat`→タイムスタンプが進むこと）
3. serveを起動: `.build/release/notetaked serve --output <test-dir> --owner testuser --source mic --no-diarize --start --control stdio`（stdin/stdoutは名前付きpipeかbackgroundサブシェルで扱う。既存の`.claude/skills/verify`やHANDOFF.mdの「Mac側で行う検証 1.」節にある `( sleep N; echo '{"cmd":...}' ) | ... | tee events.log` パターンを流用できる）
4. `say -v Kyoko "…"`で発話を入れ、finalなutteranceが出るまで待つ（`--no-diarize`ならほぼ即時）
5. serveのPIDを`kill -9`
6. capture-daemonのheartbeatが引き続き更新されていることを確認（＝crashの影響を受けていない証拠）
7. serveを同じ`--output`で再起動（`--start`無しでよい。`resumeIfNeeded()`が`current-session.json`を見て自動再開する）
8. 追加の発話を入れ、`stop`コマンドを送って終了
9. `<test-dir>/<prefix>.final.md`にcrash前後**両方**のutteranceが入っていることを確認（無ければC4のresume-fold不具合の再発）
10. `<prefix>.timed.jsonl`のseg数・時間軸を見て、crash直前〜resume直後の区間で大きな無音の欠落が無いことを確認（数秒〜十数秒程度の重複は既知の残存課題として許容、無音の巨大な欠落は不可）

## 検証2: capture-daemonのcrash → serveの耐性

1. 検証1の状態（両プロセス稼働中）からcapture-daemonのPIDを`kill -9`
2. serveが新規発話を拾わなくなる（音声が来ない）ことを確認 — これは正常（capture-daemonが死ねば音は途絶える。想定内）
3. capture-daemonを再起動: `.build/release/notetaked capture-daemon &`
4. `CaptureSessionRunner.start()`の冪等guardにより、serveが送り続けている（or 次に送る）`.startSession`で同じsession directoryへの書き込みが再開されることを確認（新しい発話を入れて拾われるか）

## 検証3: tmp領域の増加

検証1・2の実行中、`$TMPDIR/notetake-capture/<prefix>/*.raw`のファイルサイズを開始時・終了時で比較。テスト時間相応の線形増加であることを確認（切り詰めが無い設計なので増え続けるのは仕様、OSのtmp管理に任せる）。

## CLIでは検証できない範囲（GUI app本体が必要）

heartbeat staleness検知→SIGTERM→SIGKILL昇格→自動再起動（`Apps/Notetake/AppModel.swift`の監視ループ、`DaemonClient.terminate()`、`CaptureDaemonSupervisor`）は、実際のNotetake.app（`@MainActor`のGUIプロセス）内でしか動かない。userの本番appと同時に別buildを起動するとUserDefaults衝突のリスクがあるため、この範囲を検証するには**userに一度だけ本番appを終了してもらう**協力が必要（物理操作ではなくアプリの終了操作なので、事前にworktree buildでの検証手順を全部用意してから、この1点だけ頼む）。

## 物理操作が必要な範囲（1回で判定できるよう準備してから頼む）

pinデバイス（AirPods等）切断時のformat変化 → `RawAudioReaderCapture`が新formatのframeを黙って捨て続ける不具合（既知のC5、未修正）の実機再現・確認は、実際にAirPodsの抜き差しが要る。手順を全部スクリプト化し、抜き差しのタイミングだけuserに頼む（`.claude/skills/mac-app/scripts/audioin.sh`参照）。
