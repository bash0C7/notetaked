#!/bin/bash
# capture-daemonとserveをCLIで起動し、開始、発話、区切り、serveの強制終了と再開、
# capture-daemonの強制終了と再開、停止を一巡する。判定はcli-cycle-report.pyで行う。
# usage: cli-cycle.sh <出力先directory>（repoのrootで、make daemonの完了後に実行する）
set -uo pipefail
D="$1"
BIN=.build/release/notetaked
STATE="$HOME/Library/Application Support/Notetake/state"
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
  "$BIN" serve --output "$D/out" --owner 山田 --source both < "$D/cmd" >> "$D/events.log" 2>> "$D/serve.err" &
  echo $! > "$D/serve.pid"
  exec 3> "$D/cmd"
}
send() { printf '%s\n' "$1" >&3; }
wait_for() {
  for _ in $(seq 1 60); do
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
cp "$STATE/capture-desired.json" "$D/desired-recording.json"
cp "$STATE/capture-actual.json" "$D/actual-recording.json"

step say1
say -v Kyoko "一つ目の確認です。時刻が壁時計に合っているかを確かめます。"
sleep 1
say -v Otoya "はい、わかりました。"
sleep 8

send '{"cmd":"rotate"}'
sleep 3
step rotated
step say2
say -v Kyoko "区切った後の発話です。"
sleep 8

kill -9 "$(cat "$D/serve.pid")"
exec 3>&-
step serve-killed
sleep 5
start_serve
wait_for 'resumed' || step serve-not-resumed
step serve-restarted
step say3
say -v Kyoko "serveを起動し直した後の発話です。"
sleep 8

kill -9 "$(cat "$D/capture.pid")"
step capture-killed
sleep 8
cp "$STATE/capture-actual.json" "$D/actual-while-dead.json"
start_capture
sleep 4
step capture-restarted
step say4
say -v Kyoko "capture-daemonを起動し直した後の発話です。"
sleep 8

send '{"cmd":"stop"}'
sleep 3
step stopped
cp "$STATE/capture-desired.json" "$D/desired-stopped.json"
sleep 2
cp "$STATE/capture-actual.json" "$D/actual-stopped.json"
send '{"cmd":"quit"}'
exec 3>&-
sleep 2
kill -TERM "$(cat "$D/capture.pid")"
sleep 2
ls -a "$STATE" > "$D/state-dir.txt"

# 起動したprocessが終わったcapture-daemonは、自分で取り込みを止めて終える
bash -c '"$0" capture-daemon 2>> "$1" & echo $! > "$2"; sleep 2' "$BIN" "$D/capture.err" "$D/orphan.pid"
sleep 3
if kill -0 "$(cat "$D/orphan.pid")" 2>/dev/null; then
  echo alive > "$D/orphan.txt"
  kill -TERM "$(cat "$D/orphan.pid")"
else
  echo exited > "$D/orphan.txt"
fi
step done
