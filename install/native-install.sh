#!/usr/bin/env bash
# Native installer for macOS / Linux / Windows (Git Bash). Installs the SAME pinned tool
# versions the container ships (read from tools.lock) plus the sbomgate CLI.
#   bash install/native-install.sh [--prefix DIR]     (default: $HOME/.sbom-cicd-toolkit)
# Afterwards:  export PATH="$PREFIX/bin:$PATH"; sbomgate tools
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

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
verify() { local got; got="$(sha256_of "$1")"; [ "$got" = "$2" ] || { echo "sha256 mismatch for $1: got $got want $2" >&2; exit 1; }; }
lock() { eval "printf '%s' \"\$${1}_SHA256_${OS}_${ARCH}\""; }
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

# tar handles both .tar.gz and .zip (bsdtar on macOS/Windows, GNU tar + unzip fallback on Linux)
extract_one() { if tar -xf "$1" -C "$TMP" "$2" 2>/dev/null; then :; else (cd "$TMP" && unzip -o -q "$1" "$2"); fi; }
EXE=""; [ "$OS" = windows ] && EXE=".exe"
extract_one "$TMP/syft.$EXT" "syft$EXE";  extract_one "$TMP/grype.$EXT" "grype$EXE"; extract_one "$TMP/trivy.$EXT" "trivy$EXE"
install -m 0755 "$TMP/syft$EXE" "$BIN/syft$EXE"; install -m 0755 "$TMP/grype$EXE" "$BIN/grype$EXE"; install -m 0755 "$TMP/trivy$EXE" "$BIN/trivy$EXE"
install -m 0755 "$TMP/yq" "$BIN/yq$EXE"; install -m 0755 "$TMP/jq" "$BIN/jq$EXE"
install -m 0755 "$HERE/bin/sbomgate" "$BIN/sbomgate"
cp "$HERE/VERSION" "$HERE/tools.lock" "$PREFIX/"
rm -rf "$TMP"
echo "installed: $(ls "$BIN" | tr '\n' ' ')"
echo "run:  export PATH=\"$BIN:\$PATH\"  &&  SBOMGATE_HOME=\"$PREFIX\" sbomgate tools"
