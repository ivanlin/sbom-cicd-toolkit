#!/usr/bin/env bash
# ⚠️ DRAFT — 未實測、等 VM。見 docs/ONPREM-DRAFT.md §5。實測前不得在任何主機執行。
#
# install-openbao.sh — single-node OpenBao (file storage, TLS) + transit key `sbom-signing` + AppRole `sbomsign`.
#
#   sudo scripts/onprem/install-openbao.sh --cert bao.crt --key bao.key            # phase 1: install + init
#   BAO_TOKEN=<root, one-time> scripts/onprem/install-openbao.sh --configure        # phase 2: after unseal
#
# init 產生 3 份 unseal 分片、門檻 2（Q-OP3：持有人待指派）。分片與 root token 只印到操作者終端機，
# 本腳本不寫檔、不送出；操作者當場分發後，phase 2 結束時撤銷 root token。
set -euo pipefail
MODE=install CERT="" KEY="" ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
while [ $# -gt 0 ]; do case "$1" in
  --cert) CERT="$2"; shift 2;; --key) KEY="$2"; shift 2;; --configure) MODE=configure; shift;;
  *) echo "unknown arg $1" >&2; exit 64;; esac; done
export BAO_ADDR="$ADDR"

if [ "$MODE" = install ]; then
  [ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
  [ -f "$CERT" ] && [ -f "$KEY" ] || { echo "usage: $0 --cert F --key F" >&2; exit 64; }
  command -v bao >/dev/null || { echo "install the OpenBao .deb from github.com/openbao/openbao/releases (pin version + sha256) first" >&2; exit 1; }
  install -d -m 0700 -o openbao -g openbao /opt/openbao/data /opt/openbao/tls
  install -m 0644 "$CERT" /opt/openbao/tls/bao.crt; install -m 0600 -o openbao "$KEY" /opt/openbao/tls/bao.key
  cat > /etc/openbao/openbao.hcl <<'HCL'
ui            = false
disable_mlock = false
storage "file" { path = "/opt/openbao/data" }
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/openbao/tls/bao.crt"
  tls_key_file  = "/opt/openbao/tls/bao.key"
}
api_addr = "https://127.0.0.1:8200"
HCL
  systemctl enable --now openbao
  echo "== init: 3 shares, threshold 2 — copy each share to its assigned holder NOW"
  bao operator init -key-shares=3 -key-threshold=2
  echo "next: bao operator unseal (x2, different holders), then run --configure with the root token"
  exit 0
fi

: "${BAO_TOKEN:?set BAO_TOKEN (root, one-time) for --configure}"
bao audit enable file file_path=/var/log/openbao/audit.log || true
bao secrets enable transit || true
bao write -f transit/keys/sbom-signing type=ecdsa-p256 exportable=false allow_plaintext_backup=false
bao policy write sbomsign - <<'HCL'
path "transit/sign/sbom-signing"   { capabilities = ["update"] }
path "transit/verify/sbom-signing" { capabilities = ["update"] }
path "transit/keys/sbom-signing"   { capabilities = ["read"] }
HCL
bao auth enable approle || true
# secret_id_bound_cidrs: runner VM + mac mini（佔位，待填）
bao write auth/approle/role/sbomsign token_policies=sbomsign token_ttl=15m token_max_ttl=1h \
  secret_id_ttl=24h secret_id_num_uses=0 secret_id_bound_cidrs="<runner-cidr>,<macmini-cidr>"
bao read -field=role_id auth/approle/role/sbomsign/role-id
echo "issue a secret_id per signer:  bao write -f auth/approle/role/sbomsign/secret-id"
echo "public key for trusted-keys:   cosign public-key --key hashivault://sbom-signing > openbao-sbom-signing.pub"
echo "then revoke the root token:     bao token revoke -self"
