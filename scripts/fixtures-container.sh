#!/usr/bin/env bash
# Run both fixtures INSIDE the toolkit container image and assert the gate verdicts.
#   scripts/fixtures-container.sh <image> <platform-label> <out-dir>
set -uo pipefail
IMG="$1"; LABEL="$2"; OUT="$3"; HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT/vuln" "$OUT/clean"; OUT="$(cd "$OUT" && pwd)"; start=$(date +%s)
docker run --rm "$IMG" tools > "$OUT/tools.json"
docker run --rm -v "$HERE/examples:/src:ro" -v "$OUT/vuln:/out"  "$IMG" scan --source /src/vuln-app  --name vuln-app  --out /out --fail-on CRITICAL; v=$?
docker run --rm -v "$HERE/examples:/src:ro" -v "$OUT/clean:/out" "$IMG" scan --source /src/clean-app --name clean-app --out /out --fail-on CRITICAL; c=$?
end=$(date +%s)
ok=true; [ "$v" = 2 ] || ok=false; [ "$c" = 0 ] || ok=false
jq -n --arg l "$LABEL" --arg i "$IMG" --argjson v "$v" --argjson c "$c" --argjson d "$((end-start))" --argjson ok "$ok" --slurpfile t "$OUT/tools.json" \
  '{platform:$l, image:$i, runtime:$t[0].platform, tools:$t[0], vuln_app_exit:$v, clean_app_exit:$c, expected:{vuln_app_exit:2, clean_app_exit:0}, duration_seconds:$d, ok:$ok}' \
  | tee "$OUT/result.json"
$ok
