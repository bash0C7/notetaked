#!/bin/bash
# capture-daemonとserveをCLIで起動し、systemの音声を収録して停止し、確定処理の結果までを一巡する。
# 判定はfinalize-check-report.pyで行う。
# usage: finalize-check.sh <出力先directory> basic（repoのrootで、make daemonの完了後に実行する）
set -uo pipefail
D="$1"
CASE="${2:-basic}"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
[ "$CASE" = basic ] || { echo "未知のケース: $CASE" >&2; exit 1; }
# appと同じ状態ファイルを使うため、appやほかのnotetakedが動いている時は始めない
if pgrep -x Notetake > /dev/null || pgrep -f 'notetaked (serve|capture-daemon)' > /dev/null; then
  echo "Notetake.appかnotetakedが動いています。止めてから実行してください" >&2
  exit 1
fi
[ -x "$BIN" ] || { echo "$BINがありません。make daemonの後に実行してください" >&2; exit 1; }
# 前の結果が残っていると、待ちと判定が前の結果で通ってしまう
if [ -n "$(ls -A "$D" 2>/dev/null)" ]; then
  echo "出力先が空ではありません: $D" >&2
  exit 1
fi
mkdir -p "$D/out" "$STATE"
: > "$D/steps.log"
trap 'kill $(cat "$D/serve.pid" "$D/capture.pid" 2>/dev/null) 2>/dev/null' EXIT

step() { printf '%s %s\n' "$(python3 -c 'import time; print(int(time.time() * 1000))')" "$1" >> "$D/steps.log"; }
desired_stopped() {
  printf '{"sources":[]}' > "$STATE/capture-desired.json.tmp"
  mv "$STATE/capture-desired.json.tmp" "$STATE/capture-desired.json"
}
start_capture() {
  "$BIN" capture-daemon 2>> "$D/capture.err" &
  echo $! > "$D/capture.pid"
}
# serveのstdinをFIFOにつなぎ、書き手を開いたままにしてEOF（quit扱い）にならないようにする
start_serve() {
  "$BIN" serve --output "$D/out" --owner 山田 --source system < "$D/cmd" >> "$D/events.log" 2>> "$D/serve.err" &
  echo $! > "$D/serve.pid"
  exec 3> "$D/cmd"
}
send() { printf '%s\n' "$1" >&3; }
wait_for() {
  local limit="${2:-60}"
  for _ in $(seq 1 "$limit"); do
    grep -q "$1" "$D/events.log" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

rm -f "$D/cmd"
mkfifo "$D/cmd"
desired_stopped
start_capture
sleep 2
start_serve
wait_for 'serve ready' || { step serve-not-ready; exit 1; }
step ready

send '{"cmd":"start"}'
sleep 3
step started

# Kyokoの文とOtoyaの文を交互に3回ずつ流す。report側がこの文で話者を突き合わせる
for i in 1 2 3; do
  step "kyoko$i"
  say -v Kyoko "これは${i}番目の確認です。今日は晴れていて、会議を始めます。"
  sleep 1
  step "otoya$i"
  say -v Otoya "はい、了解しました。資料は先ほど共有しました。"
  sleep 1
done
sleep 4

send '{"cmd":"stop"}'
step stopped
wait_for '"phase":"finalized"' 180 || step finalize-timeout
step finalize-waited
send '{"cmd":"quit"}'
exec 3>&-
sleep 2
kill -TERM "$(cat "$D/capture.pid")"
sleep 2
ls -a "$STATE" > "$D/state-dir.txt"
step done
