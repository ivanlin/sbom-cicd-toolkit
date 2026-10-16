#!/usr/bin/env bash
# ⚠️ DRAFT — 未實測、等 VM。見 docs/ONPREM-DRAFT.md §2–§3。實測前不得在任何主機執行。
#
# install-runner.sh — Ubuntu 24.04 runner VM：Docker Engine + buildx + binfmt(arm64) + Bitbucket 自架 runner。
#
#   sudo scripts/onprem/install-runner.sh --env-file /path/runner.env
#
# runner.env 由操作者本人從 Bitbucket「Add runner」頁面抄寫（只顯示一次），本腳本不產生、不印出：
#   ACCOUNT_UUID={...}  RUNNER_UUID={...}  OAUTH_CLIENT_ID=...  OAUTH_CLIENT_SECRET=...
#   RUNTIME_PREREQUISITES_ENABLED=true  WORKING_DIRECTORY=/tmp
set -euo pipefail
ENV_SRC=""
while [ $# -gt 0 ]; do case "$1" in --env-file) ENV_SRC="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 64;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$ENV_SRC" ] || { echo "usage: $0 --env-file runner.env" >&2; exit 64; }
. /etc/os-release; [ "$ID" = ubuntu ] && [ "$VERSION_ID" = "24.04" ] || echo "WARN: drafted for Ubuntu 24.04, got $ID $VERSION_ID" >&2

# 1. Docker Engine（官方 apt repo）
if ! command -v docker >/dev/null; then
  apt-get update -y && apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi
systemctl enable --now docker

# 2. QEMU binfmt for arm64 builds（每次開機要重註冊 → 交給 systemd oneshot）
cat > /etc/systemd/system/binfmt-arm64.service <<'UNIT'
[Unit]
Description=Register qemu binfmt for arm64 (sbom-cicd-toolkit buildx)
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/bin/docker run --privileged --rm tonistiigi/binfmt --install arm64
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now binfmt-arm64.service
docker buildx inspect --bootstrap >/dev/null

# 3. Bitbucket runner（憑證只進 0600 環境檔）
install -d -m 0700 /etc/sbom-runner
install -m 0600 "$ENV_SRC" /etc/sbom-runner/runner.env
cat > /etc/systemd/system/bitbucket-runner.service <<'UNIT'
[Unit]
Description=Bitbucket Pipelines self-hosted runner (sbom)
After=docker.service
Requires=docker.service
[Service]
Restart=always
ExecStartPre=-/usr/bin/docker rm -f bitbucket-runner
ExecStart=/usr/bin/docker run --rm --name bitbucket-runner \
  -v /tmp:/tmp -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  --env-file /etc/sbom-runner/runner.env \
  docker-public.packages.atlassian.com/sox/atlassian/bitbucket-pipelines-runner:1
ExecStop=/usr/bin/docker stop bitbucket-runner
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now bitbucket-runner.service
echo "runner service started; confirm 'Online' in Bitbucket → Workspace runners"
