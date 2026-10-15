#!/usr/bin/env bash
# RQ14 consistency test: compare the SET of components of two CycloneDX SBOMs, e.g. the same
# fixture scanned on GitHub Actions and on Bitbucket Pipelines. Only the component set is compared —
# vulnerability results, timestamps, serial numbers and file hashes are expected to differ.
#
#   scripts/consistency-compare.sh [--no-qualifiers] [--include-files] A.cdx.json B.cdx.json
#
# Component key = purl (fallback: name@version), nested components included, root
# (metadata.component) excluded, duplicates collapsed. syft's type=file components (manifest
# paths such as /src/app/requirements.txt, which depend on the mount point) are skipped unless
# --include-files. --no-qualifiers drops the purl "?qualifiers#subpath" part before comparing.
# Exit: 0 identical sets · 1 sets differ · 2 usage / unreadable input.  Needs: bash, jq.
set -uo pipefail
strip=false files=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-qualifiers) strip=true; shift;;
    --include-files) files=true; shift;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown option: $1" >&2; exit 2;;
    *) break;;
  esac
done
[ $# -eq 2 ] || { echo "usage: $0 [--no-qualifiers] [--include-files] A.cdx.json B.cdx.json" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[consistency] ERROR: jq not on PATH" >&2; exit 2; }
A="$1"; B="$2"
keys() {
  jq -r --argjson strip "$strip" --argjson files "$files" '
    def comps: (.components // [])[] | ., comps;
    if (.bomFormat // "") != "CycloneDX" then error("not a CycloneDX document") else . end
    | [ comps
        | select($files or (.type // "") != "file")
        | (if (.purl // "") != "" then .purl else "\(.name // "?")@\(.version // "")" end)
        | if $strip then sub("[?#].*$"; "") else . end ]
    | unique[]' "$1"
}
ka="$(keys "$A")" || { echo "[consistency] ERROR: cannot read $A as CycloneDX JSON" >&2; exit 2; }
kb="$(keys "$B")" || { echo "[consistency] ERROR: cannot read $B as CycloneDX JSON" >&2; exit 2; }
onlyA="$(comm -23 <(printf '%s\n' "$ka" | sed '/^$/d' | LC_ALL=C sort) <(printf '%s\n' "$kb" | sed '/^$/d' | LC_ALL=C sort))"
onlyB="$(comm -13 <(printf '%s\n' "$ka" | sed '/^$/d' | LC_ALL=C sort) <(printf '%s\n' "$kb" | sed '/^$/d' | LC_ALL=C sort))"
cnt() { [ -n "$1" ] || { echo 0; return; }; printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '; }
nA="$(cnt "$ka")"; nB="$(cnt "$kb")"; oA="$(cnt "$onlyA")"; oB="$(cnt "$onlyB")"
echo "A: $A  components=$nA"
echo "B: $B  components=$nB"
echo "common=$((nA - oA))  only-in-A=$oA  only-in-B=$oB"
[ "$oA" = 0 ] || { echo "--- only in A:"; printf '%s\n' "$onlyA"; }
[ "$oB" = 0 ] || { echo "--- only in B:"; printf '%s\n' "$onlyB"; }
if [ "$oA" = 0 ] && [ "$oB" = 0 ]; then echo "RESULT: IDENTICAL component sets"; exit 0; fi
echo "RESULT: DIFFERENT component sets"; exit 1
