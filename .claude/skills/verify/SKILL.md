---
name: verify
description: 検証ゲート`make verify`（swift build警告ゼロ / swift test / make app / iOS+watchOSコンパイル）を回して結果だけを報告する。修正の前後・commit前に必ず使う。Haiku subagentへの委譲用
---

# verify — 検証ゲート

```bash
cd /Users/bash/dev/src/github.com/bash0C7/notetaked && make verify > .build/logs/verify-run.log 2>&1; echo "exit=$?"
```
数分かかる。Bashのtimeoutは10分。sandbox内でxcodebuildのpackage解決が止まる時はsandboxを外す。

報告する事実（これ以外は書かない、20行以内）:
- exit code
- `tail -n 3 .build/logs/verify-run.log`（成功なら最終行`verify: OK`）
- `grep -E 'Test run with|passed|failed' .build/logs/verify-test.log | tail -n 3`
- `grep -E '\.swift:[0-9]+:[0-9]+: (warning|error):' .build/logs/verify-build.log .build/logs/verify-app.log .build/logs/verify-ios.log`（空なら`none`）
- 非0の時だけ: 失敗したlogの最初の`error:`前後30行

ゲートの結果を全件受け取ってから修正する（1件ずつ潰さない）。`make verify`を通していないものをHANDOFFで「実装済み」と書かない。
