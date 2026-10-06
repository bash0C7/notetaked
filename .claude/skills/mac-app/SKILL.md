---
name: mac-app
description: Notetake.app（メニューバーapp + daemon）を起動し、メニュー項目・設定WindowをSystem Eventsで自動操作し、画面を撮って確認する。実機 / UI検証で人の代わりに操作する時に使う
---

# mac-app — Notetake.appの起動と自動操作

前提: `make app`済み。System Events（アクセシビリティ）の許可はこのターミナルに付与済み。全て`scripts/`配下。

## 起動 / 停止
- 起動（stderrを`/tmp/notetake-app.log`へ）: `scripts/launch.sh [logpath]` — 動いていれば「終了」してから起動し、`serve ready`まで待つ
- 停止: `scripts/ntmenu.sh "終了"`

## メニューバーの操作
- 項目一覧（状態行・「次の区切り」・「接続: …」・`rotated`ログを含む）: `scripts/ntmenu.sh --list`
- 収録中は、項目一覧にsourceごとの取り込みの状態（`マイク: 取り込み中`、`system音声: 再開待ち（理由）`など）が出る
- クリック: `scripts/ntmenu.sh "収録開始"` / `"収録停止"` / `"収録を区切る"` / `"直前の収録を整形"` / `"設定…"` / `"ライブパネルを開く"`

## 設定Window（先に`ntmenu.sh "設定…"`で開く）
- 値を読む: `scripts/ntget.sh "自分の名前"` / `"自動で区切る間隔"`
- 値を入れる: `scripts/ntset.sh "<欄名>" "<値>" enter|close|""` — AXの`focused`+`value`で入れてからEnter（`enter`）またはcmd+W（`close`）。`click`+`keystroke`では入らない
- 閉じる: `osascript -e 'tell application "System Events" to tell process "Notetake" to keystroke "w" using command down'`

## 画面確認
`scripts/screenshot.sh [out.png]` → Readツールで開く。パネルは幅が狭いとtoolbarが`>>`に畳まれる（issue #3）

## 入力機器
`scripts/audioin.sh`（一覧、*が既定）/ `scripts/audioin.sh AirPods`（部分一致で既定入力を切替）。AirPodsを外すとmacOSが内蔵マイクへ戻す。入力機器が変わると、capture-daemonが`mic.meta.jsonl`へdevice行を足し、以後の発話の`input`がその機器になる（区切らなくてよい）

## 音声を入れる
`say -v Kyoko "…"`（system音声として取り込まれる。マイク経由の認識は不安定）。声を変えるなら`-v Otoya`。収録中の発話に話者は付かない
