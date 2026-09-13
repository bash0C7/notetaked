---
name: device
description: iPhone 16e / Apple Watch Series 8へNotetakeをbuild・インストール・起動し、console（Diag.log）を読み、crash logを取って要約する。実機検証の決定論的な手順
---

# device — iPhone / Watchの実機操作

端末: iPhone 16e `FE7B47C9-2CF0-5509-A52C-1C0D806CC085`（有線、ロック解除が要る）、Apple Watch Series 8 `4583DD30-701C-5787-8BAC-600F4F495DEA`（ロック解除 + Mac近接。`process launch`と`copy`はトンネルが切れやすい。起動はWatch画面から）。iPhone 13 Proは対象外。署名はproject.ymlのAutomatic + Team。無料profileは1端末3 appまで（不要なappは`xcrun devicectl device uninstall app --device <id> <bundle id>`）。

- インストール: `scripts/install.sh iphone` / `scripts/install.sh watch`（`.build/DerivedData-device`を使い`make verify`と衝突しない）
- 起動: `scripts/launch.sh iphone` / `scripts/launch.sh iphone --console`（`peer client:` / `recorder:` / `WatchRelay:`の行が読める。consoleを切ってもappは落ちない）
- 稼働確認: `xcrun devicectl device info processes --device <id> | grep -i notetake`
- crash log: `scripts/crashlogs.sh [outdir]`（Watchの分もiPhone経由で取れる。数分遅れて同期される）
- Mac側の接続確認: メニューの「接続: iPhone」（`.claude/skills/mac-app`）。`lsof -p`はIPv6リンクローカル接続を出さないので`netstat -anv`

## 検証の型
1. Mac: `mac-app`で収録開始
2. iPhone / Watchで開始→発話→停止（人の操作）
3. `recordings`skillで該当prefixのsegを見る。停止後に届いた分は`appended peer seg to <prefix>`で追記、該当セッションが無ければ`orphans.jsonl`
4. 機内モード→解除で遅延反映、iPhone再起動で二重化しないことを同じ手順で見る
