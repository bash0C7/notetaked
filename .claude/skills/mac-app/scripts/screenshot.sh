#!/bin/bash
# 画面全体をPNGに保存する（ライブパネル・設定Windowの目視確認用）。Readツールで画像として開ける。
OUT=${1:-/tmp/notetake-shot.png}
screencapture -x "$OUT" && echo "$OUT"
