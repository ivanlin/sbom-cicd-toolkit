# ⚠️ DRAFT — 未實測、等 VM

> **本文件是需求書草稿，沒有任何一步在真實環境跑過。** 等內部 runner VM 配發後才開始實測；實測前不得當成操作手冊照做，也不得據此發版。所有數字（規格、埠、路徑）都是規劃值，實測時以實際結果回填並移除本警示。
>
> 起草：2026-10-17（job 2ff20d98，SBOM 第一階段收尾 ⑦）。對應的安裝腳本草稿在 `scripts/onprem/`，同樣未實測。

# sbom-cicd-toolkit 內部化（on-prem）需求書草稿

## 1. 目的與範圍

把目前依賴外部服務的三件事搬進公司內網，讓 Bitbucket（dynashield）上的專案在**不連 GitHub／GHCR** 的情況下也能跑 SBOM＋CVE 閘門並驗證簽章：

| 現在（GitHub 版，1.2.1） | 內部化後 |
|---|---|
| 映像在 GitHub Actions 建置（QEMU 多架構）推 GHCR | 內部 runner VM 建置（QEMU arm64）推內部 registry |
| Bitbucket Pipelines 跑在 Atlassian 雲端 runner，從 GHCR 拉工具映像 | Bitbucket 自架 runner（內部 VM），從內部 registry 拉 |
| 簽章鑰：mac mini 檔案金鑰 `interim-2026-10`（到期 2027-01-13）＋未來 YubiKey | OpenBao Transit 的 `sbom-signing` 鑰（cosign `hashivault://` KMS URI），私鑰不離開 OpenBao |

不在範圍：弱點資料庫離線鏡像（grype／trivy DB 仍需對外下載，見 §8 R-OP3）、Windows／macOS 原生安裝路徑、GitHub 側既有流程的移除。

## 2. Runner VM 規格

| 項目 | 規劃值 | 依據 |
|---|---|---|
| vCPU | 4 | 掃描（syft＋grype＋trivy）＋QEMU 交叉建置同時跑 |
| RAM | 8 GB | Bitbucket 量測：掃描器需 >1 GB，docker service 3072 MB；外加 registry／OpenBao 若同機 |
| 磁碟 | 80 GB | 工具映像兩架構、被掃映像 tar（ai-gateway ≈ 數 GB）、弱點 DB 快取、registry 儲存 |
| OS | Ubuntu 24.04 LTS | |
| 軟體 | Docker Engine（官方 apt repo）、buildx、qemu-user-static／binfmt | |
| 網路 | 出站：bitbucket.org、api.bitbucket.org、弱點 DB 來源、上游工具 release（建置時）；入站：registry 443、OpenBao 8200（僅內網） | |

**待決（Q-OP1）**：registry 與 OpenBao 是否與 runner 同機。草稿預設同機（單 VM 起步），但 OpenBao 與執行不可信程式碼的 runner 同機會讓 runner 被攻破時有機會接觸 OpenBao 的記憶體與 unseal 狀態——正式上線建議分機。

## 3. Bitbucket 自架 runner 註冊

1. Bitbucket → Workspace settings（dynashield）→ Workspace runners → Add runner → 系統選 **Linux Docker**，標籤至少 `self.hosted`、`linux`、`sbom`。
2. 頁面會給一段 `docker run … docker-public.packages.atlassian.com/sox/atlassian/bitbucket-pipelines-runner` 指令，內含 `ACCOUNT_UUID`、`RUNNER_UUID`、`OAUTH_CLIENT_ID`、`OAUTH_CLIENT_SECRET`。**這四個值只在註冊當下顯示一次**，由操作者本人貼進 VM，不經任何 agent。
3. `scripts/onprem/install-runner.sh` 只負責把上述值以環境檔（`/etc/sbom-runner/runner.env`，0600）交給 systemd 管理的容器，並確保 Docker 與 binfmt 就緒。
4. 專案的 `bitbucket-pipelines.yml` 在掃描步驟加 `runs-on: [self.hosted, linux, sbom]`。

## 4. 內部 registry（registry:2，htpasswd＋TLS）

- 映像：`registry:2`（docker distribution）；資料目錄 `/srv/registry/data`。
- 認證：htpasswd（bcrypt），帳號兩個：`ci-push`（只給 runner 建置／簽章用）、`ci-pull`（給各專案 pipeline 拉映像）。registry:2 的 htpasswd 不分權限——兩個帳號實際都能 push，**真正的唯讀需要換 Harbor 或在前面加反向代理做方法過濾（Q-OP2）**。
- TLS：公司內部 CA 簽的伺服器憑證（`/srv/registry/certs/registry.crt|key`）；各 runner 與開發機把內部 CA 放進 `/etc/docker/certs.d/<registry-host>/ca.crt`。不得用 `insecure-registries`。
- cosign 簽章與 attestation 存在同一 registry（`sha256-<digest>.sig/.att` tag），registry:2 支援 OCI artifact，無須額外設定。
- 刪除：`REGISTRY_STORAGE_DELETE_ENABLED=true`，讓「不得釘用的版本」可以清（對照 GHCR 1.2.0 的處置）。

## 5. OpenBao Transit（簽章鑰）

| 項目 | 規劃 |
|---|---|
| 部署 | OpenBao 單節點、file storage（起步），TLS 8200 |
| Unseal | Shamir：**3 份分片、門檻 2**（原需求記為「3-of-2」），持有人**待指派**（Q-OP3）；分片不得集中在同一人或同一台機器 |
| Secrets engine | `transit/`，金鑰 `sbom-signing`，型別 `ecdsa-p256`，`exportable=false`、`allow_plaintext_backup=false` |
| 存取 | AppRole `sbomsign`：policy 只允許 `transit/sign/sbom-signing`、`transit/verify/sbom-signing`、`transit/keys/sbom-signing`（read，取公鑰）；secret_id TTL 短、綁 CIDR（runner／mac mini） |
| 稽核 | `audit enable file`，稽核檔另外備份 |
| cosign 接法 | `VAULT_ADDR=https://<openbao>:8200`、`VAULT_TOKEN=<AppRole 登入取得>`，`--key hashivault://sbom-signing`。cosign 的 hashivault KMS 走 Vault Transit API，OpenBao 與其 API 相容——**相容性未實測（R-OP1）** |
| 信任清單 | 公鑰以 `cosign public-key --key hashivault://sbom-signing` 取出，用 `sbomgate key-entry --purpose hardware` 產生 trusted-keys 條目後發新版 toolkit（撤換流程同 SIGNING.md） |

`sbomsign` 已支援把 KMS URI 原樣傳給 cosign（`--key hashivault://sbom-signing`），不需改程式；需要驗證的是 OpenBao 端回傳格式與 cosign 3.1.3 的相容性。

## 6. QEMU arm64 建置

- runner VM 是 amd64；arm64 映像用 `docker run --privileged --rm tonistiigi/binfmt --install arm64` 註冊 binfmt 後，`docker buildx build --platform linux/amd64,linux/arm64 --push` 建置推送內部 registry。
- 與 GitHub 版相同：版本唯一來源 `VERSION`／`tools.lock`，`Dockerfile` 內每個二進位的 sha256 都驗證，因此 QEMU 建置的產物可與 GHCR 版逐檔比對（`sbomgate check-tools`）。
- 預估：GitHub runner 上 arm64 QEMU 建置數分鐘；4 vCPU VM 時間未量測。

## 7. bitbucket-pipelines 改用內部 registry

```yaml
# 草稿：只列與現行 templates/bitbucket-pipelines.yml 的差異
definitions:
  steps:
    - step: &source-gate
        runs-on: [ self.hosted, linux, sbom ]
        script:
          - export TOOLKIT="registry.internal.example:443/sbom-cicd-toolkit@sha256:<fill-from-internal-release>"
          - echo "$REGISTRY_PULL_PASSWORD" | docker login registry.internal.example:443 -u ci-pull --password-stdin
          - docker pull "$TOOLKIT"
          - docker run --rm "$TOOLKIT" verify-toolkit --image "$TOOLKIT"   # trusted-keys 內含 OpenBao 公鑰
          # 其餘 scan 步驟不變
```

`REGISTRY_PULL_PASSWORD` 放 Bitbucket 的 secured repository variable。主機名 `registry.internal.example` 為佔位，待 IT 指派（Q-OP4）。

## 8. 與現行 GitHub 版的差異表

| 面向 | GitHub 版（現行 1.2.1） | 內部版（本草稿） | 影響／風險 |
|---|---|---|---|
| 映像建置 | GitHub Actions `release.yml`，QEMU 多架構 | runner VM 手動／排程 `buildx`，QEMU arm64 | 需自建 release 腳本；無 Actions 日誌可追 |
| 映像存放 | `ghcr.io/ivanlin/sbom-cicd-toolkit`（Public） | `registry.internal…/sbom-cicd-toolkit`（內網） | 外部協力廠商拉不到 |
| Keyless 簽章 | Sigstore（Fulcio＋Rekor） | **無**（內網不連 Sigstore） | 只剩 key 簽章一條路（D3 本來就不依賴 Rekor） |
| Key 簽章 | mac mini 檔案金鑰（過渡）→ YubiKey | OpenBao Transit `sbom-signing` | 私鑰不落地；OpenBao 可用性變成簽章的單點 |
| 消費端 pipeline | Atlassian 雲端 runner、`size: 2x`、docker 3072 MB | 自架 runner，記憶體由 VM 決定 | 雲端 build minutes 不再計費 |
| 弱點 DB | 執行時對外下載 | 同左（未鏡像） | R-OP3：內網全斷時閘門 exit 1 |
| 驗證 | `verify-toolkit` 對 GHCR digest | 對內部 registry digest，同一套 trusted-keys 機制 | 兩邊 digest 不同（建置環境不同），需各自簽 |

## 9. 風險與待決

| 代碼 | 內容 |
|---|---|
| R-OP1 | cosign `hashivault://` 對 OpenBao Transit 的相容性未實測 |
| R-OP2 | registry:2 htpasswd 無讀寫分權 |
| R-OP3 | 弱點 DB 未鏡像，內網斷線時閘門無法執行 |
| R-OP4 | 單 VM 同時跑 runner＋registry＋OpenBao 的隔離不足 |
| Q-OP1 | registry／OpenBao 是否與 runner 同機 |
| Q-OP2 | 是否改用 Harbor（分權、掃描、複寫） |
| Q-OP3 | unseal 三份分片的持有人指派 |
| Q-OP4 | registry 與 OpenBao 的內部主機名與憑證由誰簽發 |

## 10. 驗收（實測時才填）

- [ ] runner 在 Bitbucket 顯示 Online，`runs-on` 的 pipeline 由它執行
- [ ] 內部 registry 經 TLS＋htpasswd 推拉成功；未登入拉取被拒
- [ ] buildx 雙架構推送，`docker buildx imagetools inspect` 列出 amd64＋arm64
- [ ] `sbomsign … --key hashivault://sbom-signing` 簽出的 bundle 被 `verify-release` 驗過
- [ ] `verify-toolkit --image <internal digest>` PASS
- [ ] OpenBao 重啟後需 2 份分片才能 unseal；稽核檔有 sign 紀錄
