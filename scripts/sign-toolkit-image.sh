#!/usr/bin/env bash
# Key-sign a released toolkit image on the operator machine (mac mini, D2/D6). release.yml keeps its
# keyless signature; this adds the KEY signature + CycloneDX attestation that consumers verify by
# default (sbomgate verify-toolkit). No transparency log (D3).
#
#   scripts/sign-toolkit-image.sh <version> [--key URI] [--slot SLOT] [--image-repo REPO]
#        [--digest sha256:...] [--sbom FILE] [--release-repo OWNER/NAME] [--trusted-keys F]
#
#   <version>       e.g. 1.2.0 (image tag; GitHub Release tag v<version>)
#   --key           default $SBOMSIGN_KEY (file path, pkcs11:/KMS URI, or "sk" for a YubiKey)
#   --image-repo    default ghcr.io/ivanlin/sbom-cicd-toolkit (registry is a setting, D7)
#   --digest        pin the index digest explicitly; default: resolved from <repo>:<version> and
#                   cross-checked against the Release asset index-digest.txt when available
#   --sbom          CycloneDX predicate; default: Release asset sbom-cicd-toolkit.image.cdx.json (gh)
#   --release-repo  default ivanlin/sbom-cicd-toolkit
#   --trusted-keys  trust list for the final verify-toolkit (default: this checkout's policy/trusted-keys.yaml)
# Password for a file key: $COSIGN_PASSWORD, else macOS Keychain item ${SBOMSIGN_KEYCHAIN_ITEM:-sbom-signing-key}.
# Registry push credentials: the usual docker login (cosign reads ~/.docker/config.json).
# Exit 0 = signed, attested, and verify-toolkit --attestation PASS; 1 otherwise.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export SBOMGATE_HOME="$HERE"
SBOMGATE="$HERE/bin/sbomgate"
die() { printf '[sign-toolkit-image] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[sign-toolkit-image] %s\n' "$*" >&2; }

VERSION="" KEY="${SBOMSIGN_KEY:-}" SLOT="" REPO="ghcr.io/ivanlin/sbom-cicd-toolkit" DIGEST="" SBOM="" REL_REPO="ivanlin/sbom-cicd-toolkit" TK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="$2"; shift 2;; --slot) SLOT="$2"; shift 2;; --image-repo) REPO="$2"; shift 2;;
    --digest) DIGEST="$2"; shift 2;; --sbom) SBOM="$2"; shift 2;; --release-repo) REL_REPO="$2"; shift 2;;
    --trusted-keys) TK="$2"; shift 2;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) die "unknown option $1";;
    *) [ -z "$VERSION" ] || die "unexpected argument $1"; VERSION="$1"; shift;;
  esac
done
[ -n "$VERSION" ] || die "usage: scripts/sign-toolkit-image.sh <version> [--key URI] (see --help)"
for t in cosign jq; do command -v "$t" >/dev/null 2>&1 || die "$t not on PATH"; done
want="$(sed -n 's/^COSIGN_VERSION=//p' "$HERE/tools.lock")"
got="$(cosign version --json 2>/dev/null | jq -r '.gitVersion // empty' | sed 's/^v//')"
[ "$got" = "$want" ] || die "cosign ${got:-unknown} on PATH, tools.lock pins $want (RQ18)"
TK_ARGS=(); [ -z "$TK" ] || TK_ARGS=(--trusted-keys "$TK")
W="$(mktemp -d "${TMPDIR:-/tmp}/sign-toolkit.XXXXXX")"; trap 'rm -rf "$W"' EXIT

# 1. SBOM predicate + release digest (GitHub Release assets)
REL_DIGEST=""
if [ -z "$SBOM" ]; then
  command -v gh >/dev/null 2>&1 || die "gh not on PATH (or pass --sbom FILE)"
  gh release download "v$VERSION" --repo "$REL_REPO" --dir "$W" --pattern 'sbom-cicd-toolkit.image.cdx.json' --pattern 'index-digest.txt' \
    || die "cannot download the self-scan SBOM from release v$VERSION of $REL_REPO"
  SBOM="$W/sbom-cicd-toolkit.image.cdx.json"
  [ -f "$W/index-digest.txt" ] && REL_DIGEST="$(tr -d '[:space:]' < "$W/index-digest.txt")"
fi
[ -f "$SBOM" ] || die "SBOM $SBOM not found"
jq -e '.bomFormat == "CycloneDX"' "$SBOM" >/dev/null || die "$SBOM is not a CycloneDX JSON document"

# 2. digest-pinned reference
if [ -z "$DIGEST" ]; then
  command -v docker >/dev/null 2>&1 || die "docker not on PATH (or pass --digest sha256:...)"
  DIGEST="$(docker buildx imagetools inspect "$REPO:$VERSION" --format '{{json .Manifest}}' | jq -r .digest)" || die "cannot resolve $REPO:$VERSION"
fi
printf '%s' "$DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' || die "bad digest '$DIGEST'"
[ -z "$REL_DIGEST" ] || [ "$REL_DIGEST" = "$DIGEST" ] || die "registry $REPO:$VERSION is $DIGEST but release v$VERSION recorded $REL_DIGEST — tag moved?"
REF="$REPO@$DIGEST"
info "image $REF"

# 3. key + password, and the key must already be a usable trusted key (RQ15: register first, sign second)
KEY_ARGS=()
case "$KEY" in
  "") die "no key: --key URI or SBOMSIGN_KEY";;
  sk) KEY_ARGS=(--sk); [ -z "$SLOT" ] || KEY_ARGS+=(--slot "$SLOT");;
  file://*|/*|./*|../*|[!a-z]*) KEY="${KEY#file://}"; [ -r "$KEY" ] || die "key file $KEY not readable"; KEY_ARGS=(--key "$KEY"); KFILE=1;;
  *:*) KEY_ARGS=(--key "$KEY");;
  *) [ -r "$KEY" ] || die "key file $KEY not readable"; KEY_ARGS=(--key "$KEY"); KFILE=1;;
esac
if [ "${KFILE:-0}" = 1 ] && [ -z "${COSIGN_PASSWORD+set}" ] && [ "$(uname -s)" = Darwin ] && command -v security >/dev/null 2>&1; then
  COSIGN_PASSWORD="$(security find-generic-password -s "${SBOMSIGN_KEYCHAIN_ITEM:-sbom-signing-key}" -w 2>/dev/null)" \
    || die "COSIGN_PASSWORD not set and Keychain item ${SBOMSIGN_KEYCHAIN_ITEM:-sbom-signing-key} not readable"
  export COSIGN_PASSWORD
fi
cosign public-key "${KEY_ARGS[@]}" --outfile "$W/signer.pub" >/dev/null 2>"$W/pk.err" || die "key not usable: $(tail -1 "$W/pk.err")"
"$SBOMGATE" key-status --pub "$W/signer.pub" ${TK_ARGS[@]+"${TK_ARGS[@]}"} >&2 || die "the signing key is not a usable trusted key in trusted-keys.yaml"

# 4. sign + attest, no tlog (cosign 3.x needs --use-signing-config=false for --tlog-upload=false)
cosign sign "${KEY_ARGS[@]}" --use-signing-config=false --tlog-upload=false --yes "$REF" >&2 2>"$W/sign.err" \
  || die "cosign sign failed: $(grep -v -e '^WARNING' -e deprecated "$W/sign.err" | tail -1)"
info "signature pushed"
cosign attest "${KEY_ARGS[@]}" --use-signing-config=false --tlog-upload=false --type cyclonedx --predicate "$SBOM" --yes "$REF" >&2 2>"$W/attest.err" \
  || die "cosign attest failed: $(grep -v -e '^WARNING' -e deprecated "$W/attest.err" | tail -1)"
info "cyclonedx attestation pushed"

# 5. verify exactly like a consumer does
"$SBOMGATE" verify-toolkit --image "$REF" --attestation ${TK_ARGS[@]+"${TK_ARGS[@]}"} || die "verify-toolkit failed after signing"
info "done: $REF key-signed + attested; pin this ref in consumers"
