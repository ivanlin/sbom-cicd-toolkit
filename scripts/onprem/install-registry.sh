#!/usr/bin/env bash
# ⚠️ DRAFT — 未實測、等 VM。見 docs/ONPREM-DRAFT.md §4。實測前不得在任何主機執行。
#
# install-registry.sh — registry:2 with htpasswd (bcrypt) + TLS (internal CA), delete enabled.
#
#   sudo scripts/onprem/install-registry.sh --cert registry.crt --key registry.key [--port 443]
#
# 帳號密碼由操作者互動輸入（htpasswd -B 提示），本腳本不接受密碼參數、不寫進任何檔案以外的地方。
set -euo pipefail
CERT="" KEY="" PORT=443 ROOT=/srv/registry
while [ $# -gt 0 ]; do case "$1" in
  --cert) CERT="$2"; shift 2;; --key) KEY="$2"; shift 2;; --port) PORT="$2"; shift 2;;
  *) echo "unknown arg $1" >&2; exit 64;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$CERT" ] && [ -f "$KEY" ] || { echo "usage: $0 --cert F --key F" >&2; exit 64; }
command -v htpasswd >/dev/null || apt-get install -y apache2-utils
install -d -m 0750 "$ROOT"/{data,auth,certs}
install -m 0644 "$CERT" "$ROOT/certs/registry.crt"; install -m 0600 "$KEY" "$ROOT/certs/registry.key"
for u in ci-push ci-pull; do
  create=""; [ -f "$ROOT/auth/htpasswd" ] || create="-c"
  echo "password for $u:"; htpasswd -B ${create:+"$create"} "$ROOT/auth/htpasswd" "$u"
done
chmod 0640 "$ROOT/auth/htpasswd"
docker rm -f sbom-registry 2>/dev/null || true
docker run -d --restart=always --name sbom-registry -p "$PORT:5000" \
  -v "$ROOT/data:/var/lib/registry" -v "$ROOT/auth:/auth:ro" -v "$ROOT/certs:/certs:ro" \
  -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM="sbom-registry" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2
echo "smoke: curl --cacert <internal-ca.crt> -u ci-pull https://<host>:$PORT/v2/_catalog  (expect 200; without -u expect 401)"
