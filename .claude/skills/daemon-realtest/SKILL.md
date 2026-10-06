---
name: daemon-realtest
description: capture-daemonとserveをCLIで起動し、生音声の書き込み、区切り、serveとcapture-daemonの強制終了からの回復、消灯中のsystem音声の取り込みを実機で確かめる（GUIのappを使わない）
---

# daemon-realtest — capture-daemonとserveの実機検証（CLI）

**原則**: 実機検証はclaudeが自律的に行う。userに頼むのは物理操作（AirPodsの抜き差し、ロックの解除）と、画面や音が変わることの了承だけ。

## 事前の確認（毎回）

- Notetake.appを止める（`pgrep -x Notetake`、動いていれば`.claude/skills/mac-app/scripts/ntmenu.sh "終了"`）。appのcapture-daemonとserveが同じ状態ファイルを使うため、並べて動かさない。scriptは、Notetake.appかnotetakedが動いていれば何もせずに終わる
- `make daemon`の完了を待ってから`.build/release/notetaked`を起動する。署名の途中で起動すると、Gatekeeperがbinaryをゴミ箱へ移す
- scriptの出力先には、まだ無いか空のdirectoryを渡す。前の結果が残っていると待ちと判定が前の結果で通ってしまうため、scriptは空でない出力先では始めない
- 前面の`sleep`は使えないため、scriptは`run_in_background`で走らせ、終了の知らせを待つ

## 置き場所

- 状態ファイル: `~/Library/Application Support/Notetake/state/`の`capture-desired.json`（serveが書く。収録中は`recording`にprefixと生音声ディレクトリ）、`capture-actual.json`（capture-daemonが1秒ごとに書く。更新時刻が心拍）、`process.heartbeat`（serve）
- 生音声: `$TMPDIR/notetake-capture/<prefix>/`の`session.json`、`<source>.pcm`（16kHz monoのFloat32、header無し）、`<source>.meta.jsonl`（`anchor`、`device`、`state`の行）
- 生音声の時刻ごとの量と音量: `.claude/skills/recordings/scripts/pcm-coverage.py <生音声ディレクトリ> <mic|system> [区間の秒数]`

## CLIで一巡する

`scripts/cli-cycle.sh <出力先>`（約2分、system音声で`say`が流れるため、イヤホンやスピーカーから音が出る。userの在席を確かめてから走らせる）の後に`python3 scripts/cli-cycle-report.py <出力先>`。確かめる項目:

- 開始と区切りで収録が2つでき、発話が壁時計の時刻（話し始めから4秒以内）で記録される。収録中の発話に話者は付かない
- 区切りの前後でmicの生音声の時刻が続いている（取り込みを止めずに書き込み先だけを切り替える）
- serveを`kill -9`して起動し直すと、望む状態から同じ収録を引き継ぎ、`seq`を続けて書く
- capture-daemonを`kill -9`すると、serveがstatusで「capture-daemonが応答していません」を伝え、起動し直すと同じ収録へanchorを足して書き続ける
- 停止で望む状態から収録が消え、capture-daemonが書くのをやめ、`final.md`が書かれる。状態ディレクトリに一時ファイルが残らない
- 起動したprocessが終わったcapture-daemonは、自分で取り込みを止めて終える（appが落ちた後に残り、次のcapture-daemonと同じ生音声へ書くことが無い）

`FAIL`の時は、出力先の`events.log`（serveのevent）、`serve.err`、`capture.err`、`steps.log`（各段階の時刻）と、生音声の`.meta.jsonl`を読む。

## 確定を音なしで確かめる

`python3 scripts/silent-finalize.py <作業directory> <prefix>`で、`say -o`が書き出した2人分の音声から、tmpに生音声ディレクトリと出力先の`timed.jsonl`の先頭を作る。続けて`.build/release/notetaked serve --output <作業directory>/out --owner 山田 --source system`を、stdinを開いたままのFIFOにつないで起動すると、起動時の復旧が確定する。音は出ない。serveのeventは各行に`t`（epochミリ秒）を持つので、`finalize_state`の`running`から`finalized`までの時間が読める。確かめた後は、tmpの生音声ディレクトリを消す。合成音声2人が別の話者に分かれるかは、ライブラリの分け方で決まるので、合否にしない。

## 消灯中のsystem音声

`scripts/display-sleep-check.sh <出力先>`（約3分半）。userに「画面が90秒消える。点灯後にロック画面なら解除する」と伝えてから走らせる。`coverage.txt`で、`sleep-at`から`wake-at`の間の10秒区間に音声があるかを見る。

消灯中にScreenCaptureKitがsystem音声を取り込めるかは、未確認（確かめた結果をここへ書く）。

## 固定した入力機器が外れた時（物理操作が要る）

`serve --input-device <UID>`（appではライブパネルの「入力デバイス」）でAirPodsなどに固定して収録し、`blueutil --disconnect <MAC>`（または外す）。`mic.meta.jsonl`に既定の入力の`device`行が足され、`capture-actual.json`のmicが`fell_back_from_pinned: true`になり、serveが`input_reset` eventを1回だけ出す。UIDは`.claude/skills/mac-app/scripts/audioin.sh`で調べる
