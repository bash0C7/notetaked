---
name: recordings
description: 収録の成果物（<prefix>.final.md / .timed.jsonl / orphans.jsonl）と生音声、daemonログを読み、機器・source・追記の有無を要約する。実機検証の合否判定に使う
---

# recordings — 収録結果の確認

保存先の既定は`~/Downloads`（設定Windowの「保存先」）。prefixは`YYYY-MM-DD_HHmmss`。

- 最新を要約: `scripts/inspect.sh`／指定: `scripts/inspect.sh 2026-09-14_000135 [dir]`
  - final.mdの行は`HH:mm:ss **話者**（場所）: 本文`。場所は`Mac` / `AirPods` / `system` / `iPhone 12時` / `Watch`
  - segの`platform`（mac / ios / watchos）と`source`（mic / system / watch）、`input.name`
  - `speaker_name` recordは命名の記録。収録中の発話には話者が付かない（segに`speaker`が無い）
  - 停止後に届いたpeer segは`appended peer seg to <prefix>, final.md regenerated`、該当セッションが無ければ`orphans.jsonl`
- 受信cursor（冪等）: `~/Library/Application Support/Notetake/received/<device>.cursor`
- 文字起こしの遅延の目安: `received_at - end`（`ruby -rjson`で算出）
- 生音声: `scripts/pcm-coverage.py <生音声ディレクトリ> <mic|system> [区間の秒数]`で、壁時計の区間ごとの音声の量と音量を見る。生音声ディレクトリは`$TMPDIR/notetake-capture/<prefix>/`
- 整形結果: `<prefix>.polished.md`（先頭`# yyyy-MM-dd 参加者`、時刻無し）
