#!/usr/bin/env bash
# Assert the 1.3.0 exit-code contract INSIDE the toolkit image (README "1.3.0 exit codes").
#   scripts/exit-codes-container.sh <image> <out-dir>
# Each case runs in a fresh container; the "unavailable" case has no network and an empty DB cache.
set -uo pipefail
IMG="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; : > "$OUT/cases.jsonl"; fail=0
case_() {  # $1 name  $2 expected exit  $@ docker run args (after the image's entrypoint args)
  local name="$1" want="$2" got; shift 2
  "$@" > "$OUT/$name.log" 2>&1; got=$?
  if [ "$got" = "$want" ]; then s=ok; else s=FAIL; fail=1; fi
  printf '%-4s %-26s want %-3s got %s\n' "$s" "$name" "$want" "$got"
  jq -cn --arg n "$name" --argjson w "$want" --argjson g "$got" --arg s "$s" '{case:$n, expected:$w, got:$g, status:$s}' >> "$OUT/cases.jsonl"
}
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
# policy: an allowlist entry that expired
mkdir -p "$W/expired/.sbom-cicd"; cp -R "$HERE/examples/clean-app/." "$W/expired/"
printf 'version: 1\nexemptions:\n  - vulnerability: CVE-2020-0001\n    reason: exit-code fixture\n    approved_by: ci\n    approved_on: 2026-01-01\n    expires: 2026-02-01\n' > "$W/expired/.sbom-cicd/allowlist.yaml"
sed 's/^\(SYFT_BIN_SHA256_linux_[a-z0-9]*=\).*/\1deadbeef/' "$HERE/tools.lock" > "$W/bad.lock"
mkdir -p "$OUT/unav" "$OUT/vr"
case_ usage-unknown-arg   64 docker run --rm "$IMG" scan --no-such-flag
case_ usage-no-source     64 docker run --rm "$IMG" scan --out /tmp/x
case_ policy-bad-fail-on   5 docker run --rm -v "$HERE/examples:/src:ro" "$IMG" scan --source /src/clean-app --out /tmp/o --fail-on CRIT
case_ policy-expired-allow 5 docker run --rm -v "$W/expired:/src:ro" "$IMG" scan --source /src --out /tmp/o
case_ untrusted-check-tools 4 docker run --rm -v "$W/bad.lock:/bad.lock:ro" "$IMG" check-tools --lock /bad.lock
case_ unavailable-offline  3 docker run --rm --network none -v "$HERE/examples:/src:ro" -v "$OUT/unav:/out" "$IMG" scan --source /src/clean-app --name clean-app --out /out
jq -e '.result == "UNAVAILABLE" and .exit_code == 3 and .counted_at_or_above_threshold == null and (.unavailable | length) >= 1' "$OUT/unav/gate.json" >/dev/null \
  && echo "ok   unavailable gate.json shape" || { echo "FAIL unavailable gate.json shape"; fail=1; }
# verify-release: a clean scan, then the same bundle with one byte changed
docker run --rm -v "$HERE/examples:/src:ro" -v "$OUT/vr:/out" "$IMG" scan --source /src/clean-app --name clean-app --out /out >/dev/null 2>&1
case_ verify-release-ok     0 docker run --rm --network none -v "$OUT/vr:/b" "$IMG" verify-release --bundle-dir /b --skip-signature
cp -R "$OUT/vr" "$OUT/vr-tampered"; printf 'x' >> "$OUT/vr-tampered/sbom/clean-app.source.cdx.json"
case_ untrusted-tampered    4 docker run --rm --network none -v "$OUT/vr-tampered:/b" "$IMG" verify-release --bundle-dir /b --skip-signature
# 1.3.1 regression: cwd = the source tree, --out inside it
mkdir -p "$OUT/inside"; cp -R "$HERE/examples/clean-app/." "$OUT/inside/"
case_ out-inside-source      0 docker run --rm -w /src -v "$OUT/inside:/src" "$IMG" scan --source . --name inside --out ./sbom-out
docker run --rm "$IMG" exit-codes --json > "$OUT/exit-codes.json"
jq -s --arg i "$IMG" --argjson ok "$([ "$fail" = 0 ] && echo true || echo false)" '{image:$i, cases:., ok:$ok}' "$OUT/cases.jsonl" > "$OUT/result.json"
[ "$fail" = 0 ]
