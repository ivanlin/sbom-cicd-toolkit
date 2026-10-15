#!/usr/bin/env bash
# Native installer for macOS / Linux / Windows (Git Bash). Installs the SAME pinned tool
# versions the container ships (read from tools.lock: syft grype trivy yq jq cosign) plus the
# sbomgate + sbomsign CLIs and trusted-keys.yaml. Every download is checked against the asset
# sha256, every installed executable against the *_BIN_SHA256_* table (RQ11, RQ18).
#   bash install/native-install.sh [--prefix DIR]     (default: $HOME/.sbom-cicd-toolkit)
# Afterwards:  export PATH="$PREFIX/bin:$PATH"; sbomgate tools; sbomgate check-tools
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${HOME}/.sbom-cicd-toolkit"
while [ $# -gt 0 ]; do case "$1" in --prefix) PREFIX="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 64;; esac; done
. "$HERE/tools.lock"

case "$(uname -s)" in
  Darwin) OS=darwin; TRIVY_OS=macOS;;
  Linux)  OS=linux;  TRIVY_OS=Linux;;
  MINGW*|MSYS*|CYGWIN*) OS=windows; TRIVY_OS=windows;;
  *) echo "unsupported OS $(uname -s)" >&2; exit 1;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64; TRIVY_ARCH=64bit;;
  arm64|aarch64) ARCH=arm64; TRIVY_ARCH=ARM64;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1;;
esac
[ "$OS/$ARCH" = "windows/arm64" ] && { echo "windows/arm64 has no pinned binaries in tools.lock" >&2; exit 1; }

# GNU sha256sum prefixes the line with '\' when the file name contains a backslash (Git Bash paths such as
# D:\a\_temp/...); strip it so the hash compares equal.
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1 | sed 's/^\\//'; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
verify() { local got; got="$(sha256_of "$1")"; [ "$got" = "$2" ] || { echo "sha256 mismatch for $1: got $got want $2" >&2; exit 1; }; }
lock() { eval "printf '%s' \"\$${1}_SHA256_${OS}_${ARCH}\""; }
binlock() { eval "printf '%s' \"\${${1}_BIN_SHA256_${OS}_${ARCH}:-}\""; }
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

BIN="$PREFIX/bin"; TMP="$(mktemp -d)"; mkdir -p "$BIN"
EXT=tar.gz; [ "$OS" = windows ] && EXT=zip
echo "installing into $PREFIX ($OS/$ARCH)"

fetch "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${OS}_${ARCH}.${EXT}" "$TMP/syft.$EXT"; verify "$TMP/syft.$EXT" "$(lock SYFT)"
fetch "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_${OS}_${ARCH}.${EXT}" "$TMP/grype.$EXT"; verify "$TMP/grype.$EXT" "$(lock GRYPE)"
TRIVY_FILE="trivy_${TRIVY_VERSION}_${TRIVY_OS}-${TRIVY_ARCH}.${EXT}"
[ "$OS" = windows ] && TRIVY_FILE="trivy_${TRIVY_VERSION}_windows-64bit.zip"
fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${TRIVY_FILE}" "$TMP/trivy.$EXT"; verify "$TMP/trivy.$EXT" "$(lock TRIVY)"
YQ_FILE="yq_${OS}_${ARCH}"; [ "$OS" = windows ] && YQ_FILE="yq_windows_amd64.exe"
fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/${YQ_FILE}" "$TMP/yq"; verify "$TMP/yq" "$(lock YQ)"
JQ_OS=$OS; [ "$OS" = darwin ] && JQ_OS=macos
JQ_FILE="jq-${JQ_OS}-${ARCH}"; [ "$OS" = windows ] && JQ_FILE="jq-windows-amd64.exe"
fetch "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${JQ_FILE}" "$TMP/jq"; verify "$TMP/jq" "$(lock JQ)"
COSIGN_FILE="cosign-${OS}-${ARCH}"
[ "$OS" = linux ] && [ -n "${COSIGN_LINUX_VARIANT:-}" ] && COSIGN_FILE="cosign-linux-${COSIGN_LINUX_VARIANT}-${ARCH}"
[ "$OS" = windows ] && COSIGN_FILE="cosign-windows-amd64.exe"
fetch "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/${COSIGN_FILE}" "$TMP/cosign"; verify "$TMP/cosign" "$(lock COSIGN)"

# tar handles both .tar.gz and .zip (bsdtar on macOS/Windows, GNU tar + unzip fallback on Linux)
extract_one() { if tar -xf "$1" -C "$TMP" "$2" 2>/dev/null; then :; else (cd "$TMP" && unzip -o -q "$1" "$2"); fi; }
EXE=""; [ "$OS" = windows ] && EXE=".exe"
extract_one "$TMP/syft.$EXT" "syft$EXE";  extract_one "$TMP/grype.$EXT" "grype$EXE"; extract_one "$TMP/trivy.$EXT" "trivy$EXE"
install -m 0755 "$TMP/syft$EXE" "$BIN/syft$EXE"; install -m 0755 "$TMP/grype$EXE" "$BIN/grype$EXE"; install -m 0755 "$TMP/trivy$EXE" "$BIN/trivy$EXE"
install -m 0755 "$TMP/yq" "$BIN/yq$EXE"; install -m 0755 "$TMP/jq" "$BIN/jq$EXE"; install -m 0755 "$TMP/cosign" "$BIN/cosign$EXE"
install -m 0755 "$HERE/bin/sbomgate" "$BIN/sbomgate"
install -m 0755 "$HERE/bin/sbomsign" "$BIN/sbomsign"
cp "$HERE/VERSION" "$HERE/tools.lock" "$PREFIX/"
cp "$HERE/policy/trusted-keys.yaml" "$PREFIX/trusted-keys.yaml"
rm -rf "$TMP"
# installed executables vs the extracted-binary table (what `sbomgate check-tools` compares later)
for t in syft grype trivy yq jq cosign; do
  T="$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"; want="$(binlock "$T")"
  [ -n "$want" ] || { echo "${T}_BIN_SHA256_${OS}_${ARCH} missing in tools.lock" >&2; exit 1; }
  verify "$BIN/$t$EXE" "$want"
done
echo "installed: $(ls "$BIN" | tr '\n' ' ')"
# the Linux cosign build (PIV/PKCS#11) is dynamically linked against libpcsclite.so.1
if ! "$BIN/cosign$EXE" version >/dev/null 2>&1; then
  echo "ERROR: $BIN/cosign$EXE does not run on this host: $("$BIN/cosign$EXE" version 2>&1 | head -1)" >&2
  [ "$OS" = linux ] && echo "       install libpcsclite (Debian/Ubuntu: apt-get install libpcsclite1; Fedora/RHEL: dnf install pcsc-lite-libs; Alpine/Wolfi: apk add pcsc-lite)" >&2
  exit 1
fi
echo "run:  export PATH=\"$BIN:\$PATH\"  &&  SBOMGATE_HOME=\"$PREFIX\" sbomgate tools"
