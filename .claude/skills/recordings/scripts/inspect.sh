#!/bin/bash
# usage: inspect.sh [prefix|latest] [outdir]  — 収録の成果物（final.md、segの機器/source/本文、speaker_name、orphans）を要約する
set -eo pipefail
DIR=${2:-$HOME/Downloads}
P=${1:-latest}
if [ "$P" = latest ]; then P=$(ls -t "$DIR"/*.timed.jsonl | head -1 | xargs basename | sed 's/\.timed\.jsonl$//'); fi
echo "== $P"
[ -f "$DIR/$P.final.md" ] && cat "$DIR/$P.final.md" || echo "(final.md なし: 停止 / 区切り前)"
echo "-- segs (time platform source input speaker text)"
grep '"t":"seg"' "$DIR/$P.timed.jsonl" | ruby -rjson -e 'STDIN.each_line{|l| d=JSON.parse(l); t=Time.at(d["start"]/1000.0).strftime("%H:%M:%S"); puts "#{t} #{d["platform"]} #{d["source"]} #{d.dig("input","name")} #{d.dig("speaker","global")||"-"} #{d["text"].inspect}"}'
echo "-- speaker_name records"; grep '"t":"speaker_name"' "$DIR/$P.timed.jsonl" || echo "(none)"
echo "-- devices"; grep '"t":"device"' "$DIR/$P.timed.jsonl" | grep -o '"device_name":"[^"]*"\|"offset_ms":[0-9-]*' | paste - -
echo "-- orphans (last 3)"; [ -f "$DIR/orphans.jsonl" ] && tail -n 3 "$DIR/orphans.jsonl" | grep -o '"platform":"[^"]*"\|"text":"[^"]*"' | paste - - || echo "(none)"
echo "-- daemon log (appended/orphan/rotated, last 5)"; grep -E 'appended|orphan|rotated' /tmp/notetake-app.log 2>/dev/null | tail -n 5 || true
