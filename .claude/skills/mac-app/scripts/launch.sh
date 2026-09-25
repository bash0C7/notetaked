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
  if pgrep -x Notetake >/dev/null; then
    echo "Notetake.app did not exit before deployment restart" >&2
    exit 1
  fi
fi
: > "$LOG"
open --stderr "$LOG" --stdout "$LOG" "$APP"
ready=false
for _ in $(seq 1 60); do tail -n 30 "$LOG" 2>/dev/null | grep -q 'diarizer ready' && break; sleep 1; done
if tail -n 30 "$LOG" 2>/dev/null | grep -q 'diarizer ready'; then
  ready=true
fi
if [ "$ready" != true ]; then
  echo "Notetake.app did not reach diarizer ready after deployment restart" >&2
  tail -n 30 "$LOG" >&2 || true
  exit 1
fi
menu_items=$("$(dirname "$0")/ntmenu.sh" --list)
if [[ "$menu_items" == *"ログイン時自動起動を登録できませんでした: Notetake.appが見つかりません"* ]]; then
  echo "Notetake.app still reports the login-launch registration error" >&2
  exit 1
fi
if grep -q 'notetaked error:' "$LOG"; then
  echo "Notetake.app reported a daemon error after deployment restart" >&2
  tail -n 30 "$LOG" >&2 || true
  exit 1
fi
echo "launched; log=$LOG"; tail -n 3 "$LOG"
