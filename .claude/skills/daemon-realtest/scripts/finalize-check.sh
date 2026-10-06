#!/bin/bash
# capture-daemonとserveをCLIで起動し、systemの音声を収録して停止し、確定処理の結果までを一巡する。
# 判定はfinalize-check-report.pyで行う。
# usage: finalize-check.sh <出力先directory> basic|edit|crash|retry（repoのrootで、make daemonの完了後に実行する）
#   basic: 録って確定するまで
#   edit:  確定の後に改名、人数を指定した確定し直し、話者をまとめるを行う
#   crash: 確定中の子processとserveを強制終了し、serveを起動し直して確定が終わるまで
#   retry: system.pcmを読めなくして確定を失敗させ、1分後の自動の再試行で確定が終わるまで
set -uo pipefail
D="$1"
CASE="${2:-basic}"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
case "$CASE" in basic|edit|crash|retry) ;; *) echo "未知のケース: $CASE" >&2; exit 1 ;; esac
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
raw_dir() { python3 -c 'import sys, tempfile; print(tempfile.gettempdir() + "/notetake-capture/" + sys.argv[1])' "$1"; }
prefix_of() { basename "$(ls "$D"/out/*.timed.jsonl | head -1)" .timed.jsonl; }
snapshot() { cp "$D/out/$(prefix_of).final.md" "$D/$1.final.md"; cp "$D/out/$(prefix_of).speakers.json" "$D/$1.speakers.json"; }
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

PREFIX="$(prefix_of)"
RAW="$(raw_dir "$PREFIX")"
# 取り込み中のcapture-daemonは開いたhandleで書き続けられるため、読めなくするのは確定処理だけに効く
[ "$CASE" = retry ] && chmod 000 "$RAW/system.pcm"

send '{"cmd":"stop"}'
step stopped

case "$CASE" in
basic)
  wait_for '"phase":"finalized"' 180 || step finalize-timeout
  ;;
edit)
  wait_for '"phase":"finalized"' 180 || step finalize-timeout
  snapshot snap0
  step edit-rename
  send "{\"cmd\":\"rename_speaker\",\"prefix\":\"$PREFIX\",\"speaker\":\"s1\",\"name\":\"山田太郎\"}"
  sleep 3
  snapshot snap-rename
  step edit-refinalize
  send "{\"cmd\":\"refinalize\",\"prefix\":\"$PREFIX\",\"speakers\":2}"
  wait_for '"run":2' 180 || step refinalize-timeout
  sleep 2
  snapshot snap-refinalize
  step edit-merge
  send "{\"cmd\":\"merge_speakers\",\"prefix\":\"$PREFIX\",\"from\":\"s2\",\"into\":\"s1\"}"
  sleep 3
  snapshot snap-merge
  ;;
crash)
  child=""
  for _ in $(seq 1 60); do
    child="$(pgrep -f 'notetaked finalize' | head -1)"
    [ -n "$child" ] && break
    sleep 1
  done
  if [ -n "$child" ]; then
    step child-found
    kill -STOP "$child"
    kill -9 "$(cat "$D/serve.pid")"
    kill -9 "$child"
    step killed
    exec 3>&-
    wc -l < "$D/events.log" | tr -d ' ' > "$D/restart-line.txt"
    start_serve
    wait_for 'serve ready' 30 || step serve-not-ready
    step restarted
  else
    step child-not-found
  fi
  # 起動し直す前のeventに混ざらないよう、restart-line.txtより後ろだけを数える
  for _ in $(seq 1 180); do
    tail -n +"$(( $(cat "$D/restart-line.txt" 2>/dev/null || echo 0) + 1 ))" "$D/events.log" | grep -q '"phase":"finalized"' && break
    sleep 1
  done
  ;;
retry)
  wait_for '"phase":"failed"' 120 || step failed-timeout
  cat "$RAW/finalize-attempts" > "$D/attempts-after-failure.txt" 2>/dev/null
  chmod 644 "$RAW/system.pcm"
  step unlocked
  wait_for '"phase":"finalized"' 150 || step finalize-timeout
  ;;
esac
step finalize-waited
ls -a "$RAW" > "$D/raw-dir.txt"
send '{"cmd":"quit"}'
exec 3>&-
sleep 2
kill -TERM "$(cat "$D/capture.pid")"
sleep 2
ls -a "$STATE" > "$D/state-dir.txt"
step done
