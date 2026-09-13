#!/bin/bash
# usage: launch.sh iphone|watch [--console]  — appを起動する。--consoleでstderr（Diag.log）を標準出力へ流し続ける（前面で回すかrun_in_backgroundで）
set -eo pipefail
IPHONE=FE7B47C9-2CF0-5509-A52C-1C0D806CC085; WATCH=4583DD30-701C-5787-8BAC-600F4F495DEA
case "$1" in
  iphone) DEV=$IPHONE; ID=io.github.bash0c7.notetake.ios ;;
  watch)  DEV=$WATCH;  ID=io.github.bash0c7.notetake.ios.watchkitapp ;;
  *) echo "usage: $0 iphone|watch [--console]"; exit 2 ;;
esac
if [ "$2" = "--console" ]; then
  exec xcrun devicectl device process launch --device $DEV --console --terminate-existing $ID
else
  xcrun devicectl device process launch --device $DEV --terminate-existing $ID 2>&1 | tail -n 2
fi
