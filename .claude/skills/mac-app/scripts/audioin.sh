#!/bin/bash
# 入力機器を一覧（*が既定）/ 名前の部分一致で既定入力を切り替える。初回にswiftcでbuildする。
set -eo pipefail
D=$(dirname "$0"); BIN=$D/.audioin
[ -x "$BIN" ] && [ "$BIN" -nt "$D/audioin.swift" ] || swiftc -O -o "$BIN" "$D/audioin.swift" 2>/dev/null
"$BIN" "$@"
