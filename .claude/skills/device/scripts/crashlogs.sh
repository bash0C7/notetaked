#!/bin/bash
# iPhoneのcrash logをコピーし（Watchのcrash logもProxiedDevice-*/配下に同期される）、Notetake関連を列挙して
# 各logの例外種別・落ちたthreadのframeを要約する。usage: crashlogs.sh [outdir]
set -eo pipefail
IPHONE=FE7B47C9-2CF0-5509-A52C-1C0D806CC085
OUT=${1:-/tmp/notetake-crashlogs}; rm -rf "$OUT"; mkdir -p "$OUT"
xcrun devicectl device copy from --device $IPHONE --domain-type systemCrashLogs --source . --destination "$OUT" >/dev/null 2>&1
find "$OUT" -iname 'Notetake*.ips' | sort | while read -r F; do
  echo "== $F"
  tail -n +2 "$F" | ruby -rjson -e 'd=JSON.parse(STDIN.read); puts "exception=#{d["exception"].inspect}"; puts "termination=#{d["termination"].inspect}"; ft=d["faultingThread"]; t=d["threads"][ft]; puts "thread #{ft} queue=#{t["queue"].inspect}"; fr=d["lastExceptionBacktrace"]||t["frames"]; fr.first(20).each{|f| im=d["usedImages"][f["imageIndex"]]; puts "  #{im["name"]} +#{f["imageOffset"]} #{f["symbol"]}"}'
done
echo "symbolicate: atos -o <App>.debug.dylib -arch <arch> -l 0x0 0x<imageOffset in hex>"
