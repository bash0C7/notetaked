#!/bin/bash
# Notetake.app（make appの成果物）をstderr/stdoutを/tmp/notetake-app.logへ流して起動する。
# 直接binaryを起動するとメニューバーUIが壊れるため必ず`open`を使う。既に動いていればメニューの「終了」で止めてから起動する。
set -eo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
APP=$ROOT/.build/DerivedData/Build/Products/Debug/Notetake.app
LOG=${1:-/tmp/notetake-app.log}
if pgrep -x Notetake >/dev/null; then
  "$(dirname "$0")/ntmenu.sh" "終了" >/dev/null || true
  for _ in $(seq 1 20); do pgrep -x Notetake >/dev/null || break; sleep 0.5; done
fi
open --stderr "$LOG" --stdout "$LOG" "$APP"
for _ in $(seq 1 60); do tail -n 30 "$LOG" 2>/dev/null | grep -q 'diarizer ready' && break; sleep 1; done
echo "launched; log=$LOG"; tail -n 3 "$LOG"
