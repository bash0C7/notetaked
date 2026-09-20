---
name: recordings
description: 収録の成果物（<prefix>.final.md / .timed.jsonl / .speakers.json / orphans.jsonl）とdaemonログを読み、機器・source・話者・追記の有無を要約する。実機検証の合否判定に使う
---

# recordings — 収録結果の確認

保存先の既定は`~/Downloads`（設定Windowの「保存先」）。prefixは`YYYY-MM-DD_HHmmss`。

- 最新を要約: `scripts/inspect.sh`／指定: `scripts/inspect.sh 2026-09-14_000135 [dir]`
  - final.mdの行は`HH:mm:ss **話者**（場所）: 本文`。場所は`Mac` / `AirPods` / `system` / `iPhone 12時` / `Watch`
  - segの`platform`（mac / ios / watchos）と`source`（mic / system / watch）、`input.name`、`speaker.global`
  - `speaker_name` recordはprofile由来（capture初出）またはrename
  - 停止後に届いたpeer segは`appended peer seg to <prefix>, final.md regenerated`、該当セッションが無ければ`orphans.jsonl`
- 話者の大域profile: `~/Library/Application Support/Notetake/speakers.json`（`name`付きcentroid）。cosine類似は`ruby -rjson`で計算できる（`SpeakerRegistry.Config.threshold` 0.7）
- 受信cursor（冪等）: `~/Library/Application Support/Notetake/received/<device>.cursor`
- 分離の遅延目安: `received_at - end`（`ruby -rjson`で算出）
- 整形結果: `<prefix>.polished.md`（先頭`# yyyy-MM-dd 参加者`、時刻無し）
- issue #8検証（短い相槌の話者分裂、区切り/停止時の第二パス`resolveFallbackSpeakers()`の効果確認）: `scripts/fallback-diff.sh [prefix|latest] [dir]`。実際のfinal.md（第二パス適用済み）と`notetaked render`での再生成（第二パス無し、ライブ表示相当）をdiffし、第二パスがどの行の話者を変えたかを示す。final.mdは実行後に元へ復元される
