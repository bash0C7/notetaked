#!/bin/bash
# usage: fallback-diff.sh [prefix|latest] [outdir]  — issue #8検証用
# resolveFallbackSpeakers()（区切り/停止時の第二パス）が、ライブ表示時点の話者付け
# （causalなinheritedSpeakerIDのみ、Reconciler.foldそのまま）からどの行を変えたかを、
# 実際のfinal.md（第二パス適用済み）と`notetaked render`での再生成結果（第二パス無し）を
# diffして示す。final.mdは一時退避してから元に戻すので実行後も破壊されない
set -eo pipefail
DIR=${2:-$HOME/Downloads}
P=${1:-latest}
if [ "$P" = latest ]; then P=$(ls -t "$DIR"/*.timed.jsonl | head -1 | xargs basename | sed 's/\.timed\.jsonl$//'); fi
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
FINAL="$DIR/$P.final.md"
[ -f "$FINAL" ] || { echo "no such file: $FINAL"; exit 1; }
BACKUP=$(mktemp)
cp "$FINAL" "$BACKUP"
"$ROOT/.build/release/notetaked" render "$DIR/$P.timed.jsonl" >/dev/null
echo "== $P: 第二パス無し(render再生成, '<') vs 実際のfinal.md(第二パス適用済み, '>')"
diff "$FINAL" "$BACKUP" || true
mv "$BACKUP" "$FINAL"
echo "== final.mdは元の内容へ復元済み"
