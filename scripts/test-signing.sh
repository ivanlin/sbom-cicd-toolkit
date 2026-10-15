#!/usr/bin/env bash
# End-to-end test of the signing chain (sbomsign -> evidence branch -> verify-release) with
# THROWAWAY keys only. Never touches ~/.sbom-cicd, the Keychain or a real key.
#
#   scripts/test-signing.sh <toolkit-image> [--registry-port 5055] [--keep]
#     <toolkit-image>  a locally loaded toolkit image (e.g. sbom-cicd-toolkit:1.2.0-local); it is
#                      pushed to a throwaway registry:2 (container sbom-test-registry on
#                      127.0.0.1:<port>), signed there with the throwaway key, and used by sbomsign
#                      in --mode docker (which verifies that signature first, RQ2).
#     --keep           keep the temp dir (keys are throwaway; printed path) for inspection
# Needs on PATH: docker git jq yq cosign (= tools.lock COSIGN_VERSION); uses bin/sbomgate + bin/sbomsign of this repo.
# Prints one line per assertion "AC..: PASS|FAIL — detail"; exit 0 only if all PASS.
# shellcheck disable=SC2016,SC2012  # jq programs use $vars; fixture file names are plain
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-}"; [ -n "$IMG" ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
shift
PORT=5055 KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in --registry-port) PORT="$2"; shift 2;; --keep) KEEP=1; shift;; *) echo "unknown argument $1" >&2; exit 64;; esac
done
for t in docker git jq yq cosign; do command -v "$t" >/dev/null 2>&1 || { echo "missing $t on PATH" >&2; exit 1; }; done
SBOMGATE="$HERE/bin/sbomgate"; SBOMSIGN="$HERE/bin/sbomsign"
export SBOMGATE_HOME="$HERE"
unset SBOMSIGN_KEY SBOMSIGN_IMAGE SBOMSIGN_LOG SBOMGATE_TRUSTED_KEYS 2>/dev/null || true
# git identity for the test commits only (no global config change)
export GIT_AUTHOR_NAME="sbom test" GIT_AUTHOR_EMAIL="sbom-test@example.invalid" GIT_COMMITTER_NAME="sbom test" GIT_COMMITTER_EMAIL="sbom-test@example.invalid"
# throwaway key password, only in this process environment
COSIGN_PASSWORD="test-$(date +%s)-$$-throwaway"; export COSIGN_PASSWORD

T="$(mktemp -d "${TMPDIR:-/tmp}/sbomsign-test.XXXXXX")"; T="$(cd "$T" && pwd -P)"
REG_STARTED=0; PUSHED=""
cleanup() {
  [ "$REG_STARTED" = 1 ] && docker rm -f sbom-test-registry >/dev/null 2>&1
  [ -n "$PUSHED" ] && docker rmi "$PUSHED" >/dev/null 2>&1
  if [ "$KEEP" = 1 ]; then echo "kept $T" >&2; else rm -rf "$T"; fi
  return 0
}
trap cleanup EXIT

RESULTS="$T/results"; : > "$RESULTS"
step() { printf '\n===== %s =====\n' "$*" >&2; }
assert() {  # $1 code  $2 PASS|FAIL  $3 detail
  printf '%s: %s — %s\n' "$1" "$2" "$3" | tee -a "$RESULTS" >&2
}
check() {  # $1 code  $2 detail  -- command... : PASS if command exits 0
  local code="$1" d="$2"; shift 2
  if "$@"; then assert "$code" PASS "$d"; else assert "$code" FAIL "$d"; fi
}
today() { date -u +%Y-%m-%d; }
dadd() { local n="$2"; case "$n" in -*) ;; *) n="+$n";; esac; date -u -d "$1 $2 days" +%Y-%m-%d 2>/dev/null || date -u -j -v"${n}d" -f %Y-%m-%d "$1" +%Y-%m-%d; }
vr() { "$SBOMGATE" verify-release "$@"; }   # host verify-release
evidence_clone() {  # $1 bare remote  $2 dest -> checkout of sbom-evidence
  git clone -q --branch sbom-evidence --single-branch "$1" "$2"
}
files_exist() { local f; for f in "$@"; do [ -f "$f" ] || return 1; done; }
has_branch() { git --git-dir="$1" rev-parse -q --verify refs/heads/sbom-evidence >/dev/null 2>&1; }

step "throwaway keys + trusted-keys"
mkdir -p "$T/keys"
( cd "$T/keys" && cosign generate-key-pair --output-key-prefix k1 >/dev/null 2>&1 && cosign generate-key-pair --output-key-prefix k2 >/dev/null 2>&1 )
TODAY="$(today)"
{ echo "version: 1"; echo "keys:"; "$SBOMGATE" key-entry --pub "$T/keys/k1.pub" --id test-k1 --purpose interim --days 90 --from "$(dadd "$TODAY" -1)" --note "throwaway test key 1"; } > "$T/tk1.yaml"
"$SBOMGATE" key-entry --pub "$T/keys/k2.pub" --id test-k2 --purpose hardware --days 365 --from "$(dadd "$TODAY" -1)" --note "throwaway test key 2" > "$T/k2.entry"
cat "$T/tk1.yaml" >&2
fp_openssl=""
command -v openssl >/dev/null 2>&1 && fp_openssl="$(openssl pkey -pubin -in "$T/keys/k1.pub" -outform DER | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
fp_entry="$(yq -r '.keys[0].fingerprint' "$T/tk1.yaml")"
if [ -n "$fp_openssl" ]; then check KEYENTRY "key-entry fingerprint equals openssl DER sha256 ($fp_entry)" [ "$fp_entry" = "sha256:$fp_openssl" ]; fi

step "throwaway registry + signed toolkit image"
if ! curl -fsS "http://127.0.0.1:$PORT/v2/" >/dev/null 2>&1; then
  docker rm -f sbom-test-registry >/dev/null 2>&1 || true
  docker run -d --name sbom-test-registry -p "127.0.0.1:$PORT:5000" registry:2 >/dev/null; REG_STARTED=1
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS "http://127.0.0.1:$PORT/v2/" >/dev/null 2>&1 && break; sleep 1; done
fi
PUSHED="localhost:$PORT/sbom-cicd-toolkit:test"
docker tag "$IMG" "$PUSHED"
docker push -q "$PUSHED" >/dev/null
DIGEST="$(docker buildx imagetools inspect "$PUSHED" --format '{{json .Manifest}}' | jq -r .digest)"
IMG_REF="localhost:$PORT/sbom-cicd-toolkit@$DIGEST"
echo "toolkit under test: $IMG_REF" >&2
cosign sign --key "$T/keys/k1.key" --use-signing-config=false --tlog-upload=false --yes "$IMG_REF" >/dev/null 2>&1
check TOOLKIT "verify-toolkit (host) accepts the k1-signed image" "$SBOMGATE" verify-toolkit --image "$IMG_REF" --trusted-keys "$T/tk1.yaml"
check TOOLKIT "verify-toolkit needs no internet (HTTP(S)_PROXY -> dead port; only the loopback registry is reachable)" \
  env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 NO_PROXY= no_proxy= \
  "$SBOMGATE" verify-toolkit --image "$IMG_REF" --trusted-keys "$T/tk1.yaml"
check TOOLKIT "verify-toolkit refuses a tag-only ref (exit 1)" bash -c "! '$SBOMGATE' verify-toolkit --image '$PUSHED' --trusted-keys '$T/tk1.yaml' 2>/dev/null"

step "source repo (examples/clean-app) tagged v0.0.1 + bare remote"
mkdir -p "$T/src"; cp -R "$HERE/examples/clean-app/." "$T/src/"
git -C "$T/src" init -q; git -C "$T/src" add -A; git -C "$T/src" commit -q -m "clean-app fixture"; git -C "$T/src" tag v0.0.1
SHA="$(git -C "$T/src" rev-parse HEAD)"
git clone -q --bare "$T/src" "$T/remote.git"
git clone -q --bare "$T/src" "$T/remote5.git"
LOG="$T/signing-log.jsonl"
COMMON=(--key "$T/keys/k1.key" --image "$IMG_REF" --trusted-keys "$T/tk1.yaml" --log "$LOG")

step "sbomsign --no-publish"
rc=0; "$SBOMSIGN" "$T/remote.git" v0.0.1 "${COMMON[@]}" --out "$T/ev-nopub" --no-publish || rc=$?
check NOPUB "sbomsign --no-publish exit 0" [ "$rc" = 0 ]
check NOPUB "--out has gate.json + bundle" files_exist "$T/ev-nopub/gate.json" "$T/ev-nopub/gate.json.test-k1.sigstore.json"
check NOPUB "remote has no sbom-evidence branch after --no-publish" bash -c "! git --git-dir='$T/remote.git' rev-parse -q --verify refs/heads/sbom-evidence >/dev/null"
check RQ9 "gate.json schema 2 + source.git_sha=$SHA + artifacts[] incl. gate/tools.json" \
  jq -e --arg s "$SHA" '.schema == 2 and .source.git_sha == $s and .source.git_ref == "v0.0.1" and (.source.remote_url | length > 0)
     and (.artifacts | length > 3) and (.artifacts | map(.path) | index("gate/tools.json") != null)
     and (.artifacts | map(.path) | any(startswith("sbom/"))) and (.artifacts | map(.path) | index("gate.json") == null)' "$T/ev-nopub/gate.json"

step "sbomsign publish to the bare remote (orphan branch)"
rc=0; "$SBOMSIGN" "$T/remote.git" v0.0.1 "${COMMON[@]}" --out "$T/ev" || rc=$?
check PUBLISH "sbomsign publish exit 0" [ "$rc" = 0 ]
check PUBLISH "remote has sbom-evidence branch" has_branch "$T/remote.git"
evidence_clone "$T/remote.git" "$T/branch1"
check PUBLISH "branch has v0.0.1/gate.json + v0.0.1/gate.json.test-k1.sigstore.json" files_exist "$T/branch1/v0.0.1/gate.json" "$T/branch1/v0.0.1/gate.json.test-k1.sigstore.json"
check PUBLISH "evidence branch is an orphan (no parent, unrelated to the source history)" bash -c "[ \"\$(git -C '$T/branch1' rev-list --count HEAD)\" = 1 ] && ! git -C '$T/branch1' merge-base HEAD $SHA >/dev/null 2>&1"
rc=0; "$SBOMSIGN" "$T/remote.git" v0.0.1 "${COMMON[@]}" --out "$T/ev-dup" 2>"$T/dup.err" || rc=$?
check PUBLISH "second sign of the same tag refused (exit 1, already published)" bash -c "[ $rc = 1 ] && grep -q 'already published' '$T/dup.err' && [ ! -e '$T/ev-dup' ]"

step "AC1: offline verify-release inside the container (--network none)"
rc=0; docker run --rm --network none -v "$T/ev:/b:ro" -v "$T/tk1.yaml:/tk/trusted-keys.yaml:ro" "$IMG" \
  verify-release --bundle-dir /b --expect-sha "$SHA" --trusted-keys /tk/trusted-keys.yaml || rc=$?
check AC1 "container verify-release --network none on --out evidence exit 0" [ "$rc" = 0 ]
rc=0; docker run --rm --network none -v "$T/branch1/v0.0.1:/b:ro" -e SBOMGATE_TRUSTED_KEYS=/tk/trusted-keys.yaml -v "$T/tk1.yaml:/tk/trusted-keys.yaml:ro" "$IMG" \
  verify-release --bundle-dir /b --expect-sha "${SHA:0:12}" || rc=$?
check AC1 "container verify-release --network none on the evidence branch copy (short sha, \$SBOMGATE_TRUSTED_KEYS) exit 0" [ "$rc" = 0 ]
rc=0; docker run --rm --network none -v "$T/ev:/b:ro" "$IMG" verify-release --bundle-dir /b --expect-sha "$SHA" 2>/dev/null || rc=$?
check AC1 "built-in trusted-keys.yaml (keys: []) does not accept the throwaway key (exit 1)" [ "$rc" = 1 ]
rc=0; vr --bundle-dir "$T/ev" --expect-sha 0000000 --trusted-keys "$T/tk1.yaml" 2>/dev/null || rc=$?
check AC1 "wrong --expect-sha -> exit 1" [ "$rc" = 1 ]

step "AC2: tampering"
cp -R "$T/ev" "$T/ac2"
SB="$(cd "$T/ac2" && ls sbom/*.cdx.json | head -1)"
cp "$T/ac2/$SB" "$T/sb.orig"
c="$(dd if="$T/ac2/$SB" bs=1 skip=20 count=1 2>/dev/null)"; [ "$c" = "Z" ] && n="Y" || n="Z"
printf '%s' "$n" | dd of="$T/ac2/$SB" bs=1 seek=20 count=1 conv=notrunc 2>/dev/null
rc=0; vr --bundle-dir "$T/ac2" --trusted-keys "$T/tk1.yaml" 2>"$T/ac2a.err" || rc=$?
check AC2 "1 byte flipped in $SB -> exit 1 with 'FAIL artifact-hash'" bash -c "[ $rc = 1 ] && grep -q '^FAIL artifact-hash: $SB' '$T/ac2a.err'"
cp "$T/sb.orig" "$T/ac2/$SB"
rc=0; vr --bundle-dir "$T/ac2" --trusted-keys "$T/tk1.yaml" 2>/dev/null || rc=$?
check AC2 "restored -> exit 0" [ "$rc" = 0 ]
sed -E 's/("timestamp": ")([0-9])/\1X/' "$T/ac2/gate.json" > "$T/g.tmp" && cat "$T/g.tmp" > "$T/ac2/gate.json"
check AC2 "gate.json still valid JSON after the byte flip" jq -e . "$T/ac2/gate.json" >/dev/null
rc=0; vr --bundle-dir "$T/ac2" --trusted-keys "$T/tk1.yaml" 2>"$T/ac2b.err" || rc=$?
check AC2 "1 byte flipped in gate.json -> exit 1 signature-invalid" bash -c "[ $rc = 1 ] && grep -q 'signature-invalid' '$T/ac2b.err'"

step "AC3: revoked / expired keys"
yq '.keys[0].status = "revoked" | .keys[0].revoked_on = "'"$TODAY"'"' "$T/tk1.yaml" > "$T/tk-revoked.yaml"
rc=0; vr --bundle-dir "$T/ev" --trusted-keys "$T/tk-revoked.yaml" 2>"$T/ac3a.err" || rc=$?
check AC3 "key status revoked -> exit 1 key-revoked" bash -c "[ $rc = 1 ] && grep -q 'key-revoked' '$T/ac3a.err'"
yq '.keys[0].valid_from = "'"$(dadd "$TODAY" -100)"'" | .keys[0].valid_until = "'"$(dadd "$TODAY" -1)"'"' "$T/tk1.yaml" > "$T/tk-expired.yaml"
rc=0; vr --bundle-dir "$T/ev" --trusted-keys "$T/tk-expired.yaml" 2>"$T/ac3b.err" || rc=$?
check AC3 "valid_until yesterday -> exit 1 key-expired" bash -c "[ $rc = 1 ] && grep -q 'key-expired' '$T/ac3b.err'"
rc=0; vr --bundle-dir "$T/ev" --trusted-keys "$T/tk-expired.yaml" --at "$(dadd "$TODAY" -50)" 2>/dev/null || rc=$?
check AC3 "same expired copy with --at inside validity -> exit 0 (date logic)" [ "$rc" = 0 ]
rc=0; vr --bundle-dir "$T/ev" --trusted-keys "$T/tk1.yaml" --at "$(dadd "$TODAY" -5)" 2>"$T/ac3c.err" || rc=$?
check AC3 "--at before valid_from -> exit 1 key-not-yet-valid" bash -c "[ $rc = 1 ] && grep -q 'key-not-yet-valid' '$T/ac3c.err'"
yq '.keys[0].fingerprint = "sha256:0000000000000000000000000000000000000000000000000000000000000000"' "$T/tk1.yaml" > "$T/tk-badfp.yaml"
rc=0; vr --bundle-dir "$T/ev" --trusted-keys "$T/tk-badfp.yaml" 2>/dev/null || rc=$?
check AC3 "entry whose fingerprint does not match its public_key is ignored -> exit 1" [ "$rc" = 1 ]
yq '.keys = []' "$T/tk1.yaml" > "$T/tk-empty.yaml"
rc=0; vr --bundle-dir "$T/ev" --trusted-keys "$T/tk-empty.yaml" 2>"$T/ac3d.err" || rc=$?
check AC3 "unknown key -> exit 1 key-unknown" bash -c "[ $rc = 1 ] && grep -q 'key-unknown' '$T/ac3d.err'"

step "AC5: key carrier unavailable -> nothing produced"
L5="$T/ac5-log.jsonl"
rc=0; "$SBOMSIGN" "$T/remote5.git" v0.0.1 --key /nonexistent/cosign.key --image "$IMG_REF" --trusted-keys "$T/tk1.yaml" --log "$L5" --out "$T/ac5a" 2>"$T/ac5a.err" || rc=$?
check AC5 "missing key file -> exit 1" [ "$rc" = 1 ]
check AC5 "missing key file -> --out absent" [ ! -e "$T/ac5a" ]
check AC5 "missing key file -> no sbom-evidence branch on the remote" bash -c "! git --git-dir='$T/remote5.git' rev-parse -q --verify refs/heads/sbom-evidence >/dev/null"
check AC5 "missing key file -> clear ERROR line" grep -q '^\[sbomsign\] ERROR: signing key file not available' "$T/ac5a.err"
rc=0; COSIGN_PASSWORD="definitely-wrong" "$SBOMSIGN" "$T/remote5.git" v0.0.1 --key "$T/keys/k1.key" --image "$IMG_REF" --trusted-keys "$T/tk1.yaml" --log "$L5" --out "$T/ac5b" 2>"$T/ac5b.err" || rc=$?
check AC5 "wrong COSIGN_PASSWORD -> exit 1" [ "$rc" = 1 ]
check AC5 "wrong COSIGN_PASSWORD -> --out absent" [ ! -e "$T/ac5b" ]
check AC5 "wrong COSIGN_PASSWORD -> no sbom-evidence branch on the remote" bash -c "! git --git-dir='$T/remote5.git' rev-parse -q --verify refs/heads/sbom-evidence >/dev/null"
check AC5 "log has 2 aborted lines (stage key-carrier)" bash -c "[ \"\$(jq -s '[.[] | select(.result == \"aborted\" and .stage == \"key-carrier\")] | length' '$L5')\" = 2 ]"
rc=0; "$SBOMSIGN" "$T/remote5.git" v0.0.1 --key "$T/keys/k2.key" --image "$IMG_REF" --trusted-keys "$T/tk1.yaml" --log "$L5" --out "$T/ac5c" 2>"$T/ac5c.err" || rc=$?
check AC5 "key not in trusted-keys -> exit 1 'not a usable trusted key', nothing produced" bash -c "[ $rc = 1 ] && grep -q 'not a usable trusted key' '$T/ac5c.err' && [ ! -e '$T/ac5c' ] && ! git --git-dir='$T/remote5.git' rev-parse -q --verify refs/heads/sbom-evidence >/dev/null"

step "RQ8: re-sign with a second key, then revoke"
{ cat "$T/tk1.yaml"; cat "$T/k2.entry"; } > "$T/tk12.yaml"
rc=0; "$SBOMSIGN" "$T/remote.git" --resign v0.0.1 --key "$T/keys/k2.key" --trusted-keys "$T/tk12.yaml" --log "$LOG" --out "$T/ev-resign" || rc=$?
check RQ8 "sbomsign --resign v0.0.1 exit 0" [ "$rc" = 0 ]
evidence_clone "$T/remote.git" "$T/branch2"
check RQ8 "branch has both bundles + rotation.json" files_exist "$T/branch2/v0.0.1/gate.json.test-k1.sigstore.json" "$T/branch2/v0.0.1/gate.json.test-k2.sigstore.json" "$T/branch2/v0.0.1/rotation.json"
check RQ8 "rotation.json records test-k1 -> test-k2 with the gate sha" jq -e --arg g "$(shasum -a 256 "$T/branch2/v0.0.1/gate.json" 2>/dev/null | cut -d' ' -f1)" '.[0].from_key_id == "test-k1" and .[0].to_key_id == "test-k2" and .[0].gate_sha256 == $g' "$T/branch2/v0.0.1/rotation.json"
check RQ8 "gate.json unchanged by the re-sign" cmp -s "$T/branch1/v0.0.1/gate.json" "$T/branch2/v0.0.1/gate.json"
rc=0; vr --bundle-dir "$T/branch2/v0.0.1" --expect-sha "$SHA" --trusted-keys "$T/tk12.yaml" --json > "$T/rq8a.json" 2>/dev/null || rc=$?
check RQ8 "verify-release PASS, both keys verified" bash -c "[ $rc = 0 ] && jq -e '.key_ids_verified == [\"test-k1\",\"test-k2\"]' '$T/rq8a.json' >/dev/null"
yq '.keys[0].status = "revoked"' "$T/tk12.yaml" > "$T/tk12-r1.yaml"
rc=0; vr --bundle-dir "$T/branch2/v0.0.1" --expect-sha "$SHA" --trusted-keys "$T/tk12-r1.yaml" --json > "$T/rq8b.json" 2>/dev/null || rc=$?
check RQ8 "key 1 revoked -> still PASS via test-k2" bash -c "[ $rc = 0 ] && jq -e '.key_ids_verified == [\"test-k2\"]' '$T/rq8b.json' >/dev/null"
rc=0; docker run --rm --network none -v "$T/branch2/v0.0.1:/b:ro" -v "$T/tk12-r1.yaml:/tk/trusted-keys.yaml:ro" "$IMG" verify-release --bundle-dir /b --expect-sha "$SHA" --trusted-keys /tk/trusted-keys.yaml 2>/dev/null || rc=$?
check RQ8 "same, offline in the container -> exit 0" [ "$rc" = 0 ]
yq '.keys[0].status = "revoked" | .keys[1].status = "revoked"' "$T/tk12.yaml" > "$T/tk12-r12.yaml"
rc=0; vr --bundle-dir "$T/branch2/v0.0.1" --expect-sha "$SHA" --trusted-keys "$T/tk12-r12.yaml" 2>/dev/null || rc=$?
check RQ8 "both keys revoked -> FAIL (exit 1)" [ "$rc" = 1 ]
rc=0; "$SBOMSIGN" "$T/remote.git" --resign v0.0.1 --key "$T/keys/k2.key" --trusted-keys "$T/tk12.yaml" --log "$LOG" --out "$T/ev-resign2" 2>"$T/rq8c.err" || rc=$?
check RQ8 "re-sign again with the same key refused (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'already signed by the current key' '$T/rq8c.err'"

step "scripts/sign-toolkit-image.sh (key signature + attestation of the toolkit image, test-k2)"
{ echo "version: 1"; echo "keys:"; cat "$T/k2.entry"; } > "$T/tk2.yaml"
rc=0; "$HERE/scripts/sign-toolkit-image.sh" test --key "$T/keys/k2.key" --image-repo "localhost:$PORT/sbom-cicd-toolkit" \
  --sbom "$(ls "$T"/ev/sbom/*.cdx.json | head -1)" --trusted-keys "$T/tk2.yaml" || rc=$?
check SIGNIMG "sign-toolkit-image.sh exit 0 (sign + attest + verify-toolkit --attestation)" [ "$rc" = 0 ]
rc=0; "$SBOMGATE" verify-toolkit --image "$IMG_REF" --trusted-keys "$T/tk2.yaml" --attestation --json > "$T/vt2.json" || rc=$?
check SIGNIMG "verify-toolkit --attestation with ONLY test-k2 trusted -> PASS via test-k2" bash -c "[ $rc = 0 ] && jq -e '.key_id == \"test-k2\" and .attestation.key_id == \"test-k2\"' '$T/vt2.json' >/dev/null"
rc=0; "$SBOMGATE" verify-toolkit --image "$IMG_REF" --trusted-keys "$T/tk12-r12.yaml" 2>/dev/null || rc=$?
check SIGNIMG "verify-toolkit with every key revoked -> exit 1" [ "$rc" = 1 ]

step "RQ7: signing log"
cat "$LOG" >&2
check RQ7 "log has ok sign + ok resign lines with required fields" jq -s -e '
  ([.[] | select(.result == "ok" and .action == "sign")] | length) >= 2 and
  ([.[] | select(.result == "ok" and .action == "resign" and .resign_of == "test-k1" and .key_id == "test-k2")] | length) == 1 and
  all(.[] | select(.result == "ok"); has("time") and has("repo") and (.sha|length == 40) and .tag == "v0.0.1" and (.gate_sha256|length == 64)
        and (.key_fingerprint|startswith("sha256:")) and has("bundle") and has("evidence_branch") and has("evidence_commit")
        and has("toolkit_image") and has("toolkit_version"))' "$LOG"

printf '\n===== summary =====\n' >&2
cat "$RESULTS"
if grep -q ': FAIL' "$RESULTS"; then echo "RESULT: FAIL ($(grep -c ': FAIL' "$RESULTS") failed, $(grep -c ': PASS' "$RESULTS") passed)"; exit 1; fi
echo "RESULT: PASS ($(grep -c ': PASS' "$RESULTS") assertions)"
