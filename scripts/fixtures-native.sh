#!/usr/bin/env bash
# Run both fixtures with the NATIVE sbomgate on PATH and assert the gate verdicts.
#   scripts/fixtures-native.sh <platform-label> <out-dir>
set -uo pipefail
LABEL="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"; start=$(date +%s)
sbomgate tools > "$OUT/tools.json"
sbomgate scan --source "$HERE/examples/vuln-app"  --name vuln-app  --out "$OUT/vuln"  --fail-on HIGH; v=$?
sbomgate scan --source "$HERE/examples/clean-app" --name clean-app --out "$OUT/clean" --fail-on HIGH; c=$?
# 1.3.1 regression: cwd = the source tree and --out inside it (sssf native mode's exact shape)
W="$(mktemp -d)"; cp -R "$HERE/examples/clean-app/." "$W/"
( cd "$W" && sbomgate scan --source . --name inside-out --out ./sbom-out --fail-on HIGH ); i=$?; rm -rf "$W"
end=$(date +%s)
ok=true; [ "$v" = 2 ] || ok=false; [ "$c" = 0 ] || ok=false; [ "$i" = 0 ] || ok=false
jq -n --arg l "$LABEL" --argjson v "$v" --argjson c "$c" --argjson d "$((end-start))" --argjson i "$i" --argjson ok "$ok" --slurpfile t "$OUT/tools.json" \
  '{platform:$l, runtime:$t[0].platform, tools:$t[0], vuln_app_exit:$v, clean_app_exit:$c, out_inside_source_exit:$i, expected:{vuln_app_exit:2, clean_app_exit:0, out_inside_source_exit:0}, duration_seconds:$d, ok:$ok}' \
  | tee "$OUT/result.json"
$ok
