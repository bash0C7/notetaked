#!/bin/bash
# capture-daemonだけを起動してsystem音声を取り込み、途中でディスプレイを90秒消灯させる。
# 消灯中もsystem音声を取り込めたかを、壁時計の10秒ごとの音声の量で確かめる。
# usage: display-sleep-check.sh <出力先directory>（repoのrootで、make daemonの完了後に実行する）
set -uo pipefail
D="$1"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
RAW="${TMPDIR:-/tmp}"
RAW="${RAW%/}/notetake-capture/display-check-$(date +%Y%m%d%H%M%S)"
# appと同じ状態ファイルを使うため、appやほかのnotetakedが動いている時は始めない
if pgrep -x Notetake > /dev/null || pgrep -f 'notetaked (serve|capture-daemon)' > /dev/null; then
  echo "Notetake.appかnotetakedが動いています。止めてから実行してください" >&2
  exit 1
fi
[ -x "$BIN" ] || { echo "$BINがありません。make daemonの後に実行してください" >&2; exit 1; }
mkdir -p "$D" "$STATE"

write_desired() {
  printf '%s' "$1" > "$STATE/capture-desired.json.tmp"
  mv "$STATE/capture-desired.json.tmp" "$STATE/capture-desired.json"
}

write_desired '{"sources":[]}'
"$BIN" capture-daemon 2> "$D/capture.err" &
DAEMON=$!
sleep 2
write_desired "{\"recording\":{\"prefix\":\"display-check\",\"directory\":\"$RAW\"},\"sources\":[\"system\"]}"
sleep 3
cp "$STATE/capture-actual.json" "$D/actual-start.json"

( for i in $(seq 1 45); do say -v Kyoko "消灯の確認、${i}番目です"; sleep 3; done ) &
SPEAKER=$!

sleep 20
date +%H:%M:%S > "$D/sleep-at"
pmset displaysleepnow
sleep 90
date +%H:%M:%S > "$D/wake-at"
caffeinate -u -t 2
sleep 40
cp "$STATE/capture-actual.json" "$D/actual-end.json"

write_desired '{"sources":[]}'
sleep 2
kill "$SPEAKER" 2>/dev/null
kill -TERM "$DAEMON"
for _ in $(seq 1 10); do
  kill -0 "$DAEMON" 2>/dev/null || break
  sleep 1
done
kill -9 "$DAEMON" 2>/dev/null
echo "$RAW" > "$D/raw-dir"
python3 .claude/skills/recordings/scripts/pcm-coverage.py "$RAW" system 10 > "$D/coverage.txt"
echo "done" > "$D/finished"
