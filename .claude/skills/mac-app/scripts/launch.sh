#!/bin/bash
# Notetake.app（make install-appで/Applicationsへ配置した成果物）をstderr/stdoutを/tmp/notetake-app.logへ流して起動する。
# 直接binaryを起動するとメニューバーUIが壊れるため必ず`open`を使う。既に動いていればメニューの「終了」で止めてから起動する。
set -eo pipefail
APP=${NOTETAKE_APP_PATH:-/Applications/Notetake.app}
LOG=${1:-/tmp/notetake-app.log}
if [ ! -d "$APP" ]; then
  echo "missing $APP; run 'make install-app' first" >&2
  exit 1
fi
if pgrep -x Notetake >/dev/null; then
  "$(dirname "$0")/ntmenu.sh" "終了" >/dev/null || true
  for _ in $(seq 1 20); do pgrep -x Notetake >/dev/null || break; sleep 0.5; done
fi
open --stderr "$LOG" --stdout "$LOG" "$APP"
for _ in $(seq 1 60); do tail -n 30 "$LOG" 2>/dev/null | grep -q 'diarizer ready' && break; sleep 1; done
echo "launched; log=$LOG"; tail -n 3 "$LOG"
