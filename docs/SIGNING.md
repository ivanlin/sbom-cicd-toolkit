# SBOM 簽章與驗證 — 操作手冊（sbom-cicd-toolkit 1.3.0）

本文件給兩種人看：**簽章操作者**（在 mac mini 上產生金鑰、簽 release、輪替金鑰）與**驗證者**（拿到證據後離線驗證）。所有指令都可以照抄；私鑰、密碼、PIN 一律由操作者本人在自己的終端機輸入，任何自動化工具（含 AI agent）都不碰。

## 1. 定位聲明

> 這套簽章的信任邊界是 mac mini 與簽章金鑰的載體。它證明「mac mini 操作者核准了這份掃描結果對應這個 commit」，不證明掃描本身誠實。過渡期的檔案金鑰等級低於硬體金鑰，文件與驗收以此為準。

## 2. 全貌

```
 產品 repo（GitHub 或 Bitbucket，任意 git URL / 本機路徑）
        │  git clone + checkout <rev>（純 git，不呼叫 provider API）
        ▼
 ┌──────────────────────────── mac mini（唯一簽章地點，D2）────────────────────────────┐
 │ sbomsign <repo> <rev>                                                                 │
 │   0 載體檢查：cosign 版本 = tools.lock、金鑰可用、公鑰指紋在 trusted-keys.yaml 且有效   │
 │   1 取原始碼 → commit sha                                                             │
 │   2 掃描：verify-toolkit（工具箱映像驗簽）→ 容器內 sbomgate scan → gate.json schema 2   │
 │   3 簽前檢查：verify-release --skip-signature（artifacts[] 雜湊、git_sha）              │
 │   4 簽章：cosign sign-blob gate.json（--tlog-upload=false，不送 Rekor，D3）             │
 │   5 簽後驗證：verify-release（含簽章）必須 PASS                                         │
 │   6 發布：push 到 orphan 分支 sbom-evidence/<tag>/（D5）                               │
 │   7 本機紀錄：~/.sbom-cicd/sbom-signing-log.jsonl（失敗也寫一行 aborted）               │
 │   任何一步失敗 → 暫存目錄整個刪除，--out 不出現、不 push（RQ5、AC5）                   │
 └───────────────────────────────────────────────────────────────────────────────────────┘
        │  git push <repo> HEAD:refs/heads/sbom-evidence
        ▼
 sbom-evidence/<tag>/ gate.json + gate.json.<keyid>.sigstore.json + sbom/ scan/ gate/
        │  git clone --branch sbom-evidence（任何人、任何 CI、可離線）
        ▼
 驗證端：sbomgate verify-release --bundle-dir <tag>/ --expect-sha <commit>
         只需要公鑰與 trusted-keys.yaml（已封裝在工具箱映像與原生安裝內），不需網路
```

簽的只有 `gate.json`（D8）。SBOM 與掃描結果的完整性由 gate.json 內 `artifacts[]`（路徑、sha256、大小）間接綁定；`gate.json` 的 `source.git_sha` 綁定 commit。

## 3. 檔案與名詞

| 名稱 | 位置 | 說明 |
|---|---|---|
| `trusted-keys.yaml` | repo `policy/trusted-keys.yaml`；映像內 `/opt/sbom-cicd-toolkit/trusted-keys.yaml`；原生安裝 prefix 內 | 驗證端唯一信任來源。每把鑰：id、purpose（interim/hardware）、status（active/revoked）、fingerprint、valid_from、valid_until（必填）、public_key。撤銷靠**發新版工具箱**傳播（R3）。 |
| 查找順序 | — | `--trusted-keys FILE` > `$SBOMGATE_TRUSTED_KEYS` > `$SBOMGATE_HOME/trusted-keys.yaml` > `$SBOMGATE_HOME/policy/trusted-keys.yaml` |
| 金鑰「可用」 | — | 在日期 T（預設今天 UTC，`--at YYYY-MM-DD` 可改）`status: active` 且 `valid_from <= T <= valid_until`。否則以 key-revoked / key-expired / key-not-yet-valid 拒收。 |
| bundle | `gate.json.<keyid>.sigstore.json` | cosign sigstore bundle v0.3（含簽章與公鑰 hint = base64(sha256(DER 公鑰))）。同一個 tag 可以有多個（輪替重簽後），**任一有效即通過**（RQ10）。 |
| 證據分支 | 產品 repo 的 `sbom-evidence`（orphan） | 每個 tag 一個目錄，見第 10 節。 |
| 本機紀錄 | `~/.sbom-cicd/sbom-signing-log.jsonl`（`--log` / `$SBOMSIGN_LOG` 可改） | 每次簽章、重簽、中止各一行 JSON（RQ7）。R1 的偵測依據。 |
| 金鑰密碼 | macOS Keychain 項目 `sbom-signing-key`（`$SBOMSIGN_KEYCHAIN_ITEM` 可改） | sbomsign 依序取 `$COSIGN_PASSWORD` → Keychain → 互動輸入（非互動環境即失敗）。 |

## 4. 前置條件（mac mini）

```bash
# 原生安裝（含 cosign 3.1.3，sha256 依 tools.lock 驗證；也裝 sbomgate、sbomsign、trusted-keys.yaml）
bash install/native-install.sh --prefix ~/.sbom-cicd/toolkit
export PATH="$HOME/.sbom-cicd/toolkit/bin:$PATH"
cosign version | grep GitVersion        # 必須是 v3.1.3（RQ18：簽驗兩端同版，不同版 sbomsign 直接 exit 1）
sbomgate check-tools                     # 六個工具全部 ok
docker version >/dev/null && echo docker-ok   # sbomsign 預設 --mode docker
```

## 5. 過渡鑰（檔案金鑰）產生 — 操作者本人執行

> **密碼絕不貼到任何地方**：不貼進聊天、Slack、工單、指令列參數、文件、截圖。下面的指令讓密碼只存在 Keychain 與當下 shell 的環境變數裡，產生後立刻 `unset`。不要用 `echo $pw` 確認。

```bash
mkdir -p ~/.sbom-cicd/keys && cd ~/.sbom-cicd/keys
# password: generate, store in Keychain, never print
pw="$(openssl rand -base64 32)"; security add-generic-password -a "$USER" -s sbom-signing-key -w "$pw" -U; unset pw
COSIGN_PASSWORD="$(security find-generic-password -s sbom-signing-key -w)" cosign generate-key-pair   # writes cosign.key (encrypted) + cosign.pub
chmod 600 cosign.key
# fingerprint for trusted-keys.yaml
openssl pkey -pubin -in cosign.pub -outform DER | shasum -a 256
```

- `cosign.key` 是加密過的私鑰，只留在 mac mini。`cosign.pub` 是公鑰，可以公開。
- 第一次讀取 Keychain 時 macOS 會跳出允許視窗，選「永遠允許」給 `security` 即可。
- Keychain 項目遺失 = 私鑰無法使用 → 只能產新鑰並依第 11 節輪替。

## 6. 登錄公鑰到 trusted-keys.yaml

```bash
cd ~/.sbom-cicd/keys
sbomgate key-entry --pub cosign.pub --id interim-2026-10 --purpose interim --days 90
```

輸出是一段可直接貼上的 YAML（id、purpose、status: active、fingerprint、valid_from 今天、valid_until 今天＋90 天、public_key）。把它貼到 toolkit repo 的 `policy/trusted-keys.yaml` 的 `keys:` 底下，確認 fingerprint 與第 5 節 `shasum` 的輸出一致，然後：

0. 確認登錄正確：`sbomgate key-status --pub cosign.pub --trusted-keys policy/trusted-keys.yaml` 應印出 `usable interim-2026-10 sha256:…` 並 exit 0（`key-unknown` = 指紋沒對上）。
1. commit `policy/trusted-keys.yaml`（PR review 就是核准紀錄）。
2. 發一版工具箱（docs/RELEASING.md）——驗證端只信任**映像／原生安裝內封裝的那份**，不發版等於驗證端看不到新鑰。
3. 以 key 簽工具箱映像：`scripts/sign-toolkit-image.sh <version>`（D6 雙簽的 key 那一半，見 RELEASING.md）。

規則：先登錄、後簽章（RQ15）。sbomsign 在第 0 步就檢查目前金鑰的指紋是否在 trusted-keys.yaml 內且可用，不在就 exit 1、不做任何事。

## 7. 簽一個 release tag（sbomsign）

```bash
export SBOMSIGN_KEY="$HOME/.sbom-cicd/keys/cosign.key"     # 或每次 --key
export SBOMSIGN_IMAGE="ghcr.io/ivanlin/sbom-cicd-toolkit@sha256:<release digest>"   # 或每次 --image
TK="$SBOMSIGN_IMAGE"

# GitHub 上的專案
sbomsign git@github.com:ivanlin/harness.git v1.4.0 --image "$TK" --name harness
# Bitbucket 上的專案 —— 同一個指令，只有 URL 不同（AC4）
sbomsign git@bitbucket.org:dynashield/harness.git v1.4.0 --image "$TK" --name harness
# 本機 checkout 也可以（remote URL 取自其 origin）
sbomsign ~/Documents/projects/harness v1.4.0 --image "$TK" --name harness
```

常用選項：

| 選項 | 說明 |
|---|---|
| `--key URI` | 預設 `$SBOMSIGN_KEY`。檔案路徑／`file://`、`pkcs11:` URI、或字面值 `sk`（YubiKey，可加 `--slot signature`）。任何 cosign 支援的 key URI 原樣轉給 cosign（D1）。 |
| `--mode docker\|native` | 預設 docker：先 `verify-toolkit` 再在容器內掃描。native：先 `sbomgate check-tools` 再用本機工具掃描。 |
| `--image REF@sha256:…` | 工具箱映像，預設 `$SBOMSIGN_IMAGE`，必須以 digest 引用；使用前一律 verify-toolkit。 |
| `--tag T` | 證據目錄名。預設：`<rev>` 是 tag 就用它；否則 HEAD 上的精確 tag；都沒有就 `sha-<12 碼>`。 |
| `--fail-on HIGH` / `--allowlist FILE` / `--image-tar FILE` | 照傳給 `sbomgate scan`。產品若有映像，用 `--image-tar` 一併納入。 |
| `--out DIR` | 本機證據副本，預設 `./sbom-evidence/<tag>`。只在簽後驗證通過後才出現。 |
| `--no-publish` | 只簽不推（先試跑或離線時）。 |
| `--evidence-branch B` / `--push-remote URL` | 證據分支名（預設 sbom-evidence）／推送目標（預設 = 來源 repo URL）。 |
| `--sign-failed` | gate FAIL 也簽（簽章是「失敗的證據」；verify-release 預設仍拒收，見第 9 節）。不加時 gate FAIL → exit 2，不簽。 |
| `--log FILE` / `--trusted-keys F` | 本機紀錄位置／使用的 trusted-keys。 |

成功時印出 tag、commit sha、gate.json 的 sha256、key id、證據分支 commit。**任何一步失敗**：暫存目錄刪除、`--out` 不存在、遠端沒有新 commit，紀錄檔多一行 `"result":"aborted","stage":"<步驟>","reason":"…"`。

推送權限（V3）：mac mini 用來 push 的帳號要能寫 `sbom-evidence` 分支；其他人不行（見第 12 節分支保護）。

## 8. 重簽（--resign，RQ8）

```bash
sbomsign git@github.com:ivanlin/harness.git --resign v1.4.0 --key <新鑰 URI>
```

流程：取出 `sbom-evidence/v1.4.0/` → `verify-release` 必須以某把**目前仍可用**的金鑰通過 → 用新鑰簽**同一份** gate.json → 新 bundle `gate.json.<新keyid>.sigstore.json` 與舊 bundle 並存 → 追加 `rotation.json`（`[{time, from_key_id, to_key_id, gate_sha256}]`）→ 再驗一次 → commit `sbom-evidence: resign v1.4.0 <舊>-><新>` → push → 紀錄 `action: "resign"`。

注意：舊鑰在重簽時必須仍是 active（D9）。先撤銷再重簽會因為舊 bundle 驗不過而失敗。

## 9. 驗證（消費端、出貨閘門）

### 9.1 驗 release 證據（離線）

```bash
REPO=git@bitbucket.org:dynashield/harness.git ; TAG=v1.4.0
TK="ghcr.io/ivanlin/sbom-cicd-toolkit@sha256:<release digest>"
git clone --quiet --depth 1 --branch sbom-evidence "$REPO" ev
SHA="$(git ls-remote "$REPO" "refs/tags/$TAG^{}" | cut -f1)"; [ -n "$SHA" ] || SHA="$(git ls-remote "$REPO" "refs/tags/$TAG" | cut -f1)"
docker run --rm --network none -v "$PWD/ev/$TAG:/b" "$TK" verify-release --bundle-dir /b --expect-sha "$SHA"
echo "exit=$?"     # 0 = 可出貨；1 = 拒收（原因逐行印在 FAIL 行）
```

verify-release 逐項印 PASS/FAIL：

1. `gate.json` 可解析且 `schema >= 2`。
2. `artifacts[]` 每一項存在且 sha256、大小相符（竄改任一 SBOM／掃描檔 → FAIL，AC2）。
3. `--expect-sha`：`source.git_sha` 等於要出貨的 commit（接受 ≥ 7 碼的唯一前綴）。
4. 至少一個 bundle 以**可用**金鑰驗證通過。每個 bundle 的狀態：verified / key-revoked / key-expired / key-unknown / signature-invalid（AC3）。多個 bundle 任一 verified 即通過。
5. `gate.json` 的 `result` 必須是 PASS（加 `--allow-fail-result` 才接受「簽了章的失敗結果」）。

其他：`--at YYYY-MM-DD` 以指定日期判斷金鑰效期（回答「簽的當下是否有效」）；`--trusted-keys F` 用指定清單（例如還沒發版的新清單）；`--json` 輸出機器報告到 stdout。原生安裝一樣可用：`sbomgate verify-release --bundle-dir ev/$TAG --expect-sha "$SHA"`。

GitHub 與 Bitbucket 的驗證流程完全相同，只有 `REPO` 不同（AC4）；不呼叫任何 provider API。

### 9.2 驗工具箱映像（verify-toolkit）

```bash
docker run --rm "$TK" verify-toolkit --image "$TK"      # 0 = 某把可用金鑰簽過這個 digest
```

- 只接受 `image@sha256:…`，只寫 tag 會 exit 64（用法錯誤，要求釘 digest；1.3.0 前為 exit 1）。
- 需要連到 registry 讀簽章（不需要 GitHub/Bitbucket API）。1.3.0 起分兩種：簽章不符／無可用信任金鑰 exit 4（不受信任，任何模式都不降級），讀不到 registry 的簽章 exit 3（外部資源不可達，不是簽章問題）；兩者都不交給 builder 修（RQ2）。1.3.0 前一律 exit 1。
- 映像自己驗自己有循環信任的疑慮；要獨立驗證，用原生安裝的 sbomgate（`sbomgate verify-toolkit --image "$TK"`），或直接用 cosign 與 trusted-keys.yaml 裡的公鑰：
  `cosign verify --key cosign.pub --insecure-ignore-tlog "$TK"`

### 9.3 只用 cosign 手動驗 gate.json（不依賴 sbomgate）

```bash
cosign verify-blob --key cosign.pub --bundle ev/v1.4.0/gate.json.interim-2026-10.sigstore.json \
  --insecure-ignore-tlog ev/v1.4.0/gate.json          # "Verified OK"
```
`--insecure-ignore-tlog` 是必要的：我們刻意不送 Rekor（D3），沒有它 cosign 會以「not enough verified log entries」拒絕。這只驗簽章，不檢查效期、撤銷與 artifacts[]——那些是 verify-release 的工作。

## 10. 證據分支結構（D5）

```
sbom-evidence            （orphan 分支，與產品程式碼歷史無關）
└── v1.4.0/
    ├── gate.json                              ← 被簽的唯一檔案（schema 2：source、artifacts[]）
    ├── gate.json.interim-2026-10.sigstore.json
    ├── gate.json.yubikey-a-2027.sigstore.json  ← 輪替重簽後才有，與舊 bundle 並存
    ├── rotation.json                           ← 重簽紀錄（僅 --resign 後）
    ├── summary.md, sbomgate.log                ← 給人看，不在 artifacts[] 內
    ├── sbom/<name>.source.cdx.json / .spdx.json（有映像時另有 <name>.image.*）
    ├── scan/grype.*.json, trivy.*.json
    └── gate/tools.json, exemptions.json, findings.grype.json, findings.trivy.json, grype-ignore.yaml …
```

commit 訊息：`sbom-evidence: <name> <tag> <sha12> key=<keyid>`；重簽：`sbom-evidence: resign <tag> <舊>-><新>`。同一 tag 已有 `gate.json` 時，非 `--resign` 一律拒絕（exit 1），要嘛 `--resign`，要嘛換 `--tag`。產品有容器映像時另以 cosign attest 附上 SBOM；provider 的 Release／Downloads 只是可選的便利層。

## 11. 過渡鑰延長與輪替

### 11.1 延長（RQ16，最多一次，必須在到期前）

1. 在 `policy/trusted-keys.yaml` 該鑰：`valid_until` 改為新日期（最多再 90 天），填 `extended_on: <今天>` 與 `extension_reason: "<原因，例如 YubiKey 交期延後>"`。
2. commit（訊息寫明延長原因）→ 發一版工具箱。
3. 已延長過的鑰不能再延長；到期前必須完成第 11.2 節輪替。

### 11.2 輪替程序（RQ15，逐步）

1. **新鑰就緒**：產生新主鑰（硬體鑰見第 12 節；或新檔案鑰見第 5 節）以及**備援鑰**。
2. **登錄**：用 `sbomgate key-entry` 產出兩筆（主鑰、備援鑰），`status: active`，**同時**加入 `policy/trusted-keys.yaml`。舊鑰不動，仍是 active。
3. **發版 #1**：發工具箱新版本（新、備援、舊三把都 active），以新鑰對映像做 key 簽章（`scripts/sign-toolkit-image.sh`），消費端改用新 digest。
4. **列出要重簽的證據**：所有仍在有效期內的正式證據（各產品 repo 的 `sbom-evidence/` 目錄），可從 `~/.sbom-cicd/sbom-signing-log.jsonl` 篩 `key_id == <舊鑰>` 且 `result == "ok"`。
5. **重簽**：每個 tag 執行 `sbomsign <repo> --resign <tag> --key <新鑰>`（第 8 節），每個都必須成功。
6. **確認全部完成**：對每個 tag 跑 `verify-release --trusted-keys <把舊鑰標 revoked 的暫存副本>`，全部 PASS 才往下（證明不靠舊鑰也能過）。
7. **撤銷舊鑰**：`status: revoked`、`revoked_on: <今天>`，commit。
8. **發版 #2**：發工具箱新版本。從此新版驗證端拒收只有舊鑰 bundle 的證據（AC6）；舊版工具箱在更新前仍接受（R3）。
9. 過渡檔案鑰：撤銷後刪除 `~/.sbom-cicd/keys/cosign.key` 與 Keychain 項目 `sbom-signing-key`（`security delete-generic-password -s sbom-signing-key`）。

## 12. YubiKey（硬體鑰，RQ17）— 操作者本人執行

前提：cosign 3.1.3 官方 macOS 版已內建 PIV 支援（V2 實測：`--sk` 無卡時回 `no cards found`）。兩支 YubiKey：A（主鑰）、B（備援）。每支分別做一次下列步驟（B 做完後離線保管）。

```bash
# 0. 只插一支。全新或要重來才 reset（會清掉卡上所有 PIV 金鑰）
cosign piv-tool reset
# 1. 設 PIN、PUK —— 不帶參數，讓 cosign 互動詢問；不要把 PIN/PUK 寫在指令列（會進 shell history）
cosign piv-tool set-pin
cosign piv-tool set-puk
# 2. 在卡內產生金鑰（不可匯出）：每次簽章都要 PIN；觸碰預設開啟
cosign piv-tool generate-key --slot signature --pin-policy always --touch-policy always --random-management-key=true
# 3. 證明金鑰是在卡內產生的（attestation），與公鑰一起留存
cosign piv-tool attestation --slot signature --output json > yubikey-a.attestation.json
# 4. 取公鑰、指紋、產生 trusted-keys 條目
cosign public-key --sk --slot signature --outfile yubikey-a.pub
openssl pkey -pubin -in yubikey-a.pub -outform DER | shasum -a 256
sbomgate key-entry --pub yubikey-a.pub --id yubikey-a-2027 --purpose hardware --days 365
```

- `--random-management-key=true`：產鑰後丟棄管理金鑰，之後任何人（含自己）都不能覆寫這個 slot，只能 reset 整張卡。
- PIN 與 PUK：A、B 各自不同，存進密碼管理器（各一筆）。不要寫在紙條貼在機器上、不要存在 mac mini 的檔案裡。PIN 連錯 3 次鎖卡，用 `cosign piv-tool unblock` 以 PUK 解；PUK 再錯完就只能 reset（金鑰消失 → 視同遺失，走輪替）。
- 觸碰要求：預設 `--touch-policy always`（每次簽章都要摸一下，防止 mac mini 失陷時被無聲使用）。若為了配合自動化要關閉（`never`）或放寬（`cached`），**由使用者決定**；policy 在產鑰時固定，事後要改只能重新產鑰並走輪替。
- 硬體鑰也必須有到期日（RQ3）；`--days` 由使用者決定（範例 365）。
- 備援 B：與 A 是兩把**獨立**金鑰（硬體金鑰無法複製），公鑰與 A 同時登錄（RQ15 第 2 步）。完成後拔下，離線保管（保險箱等與 mac mini 不同地點）。
- 簽章：`sbomsign <repo> <tag> --key sk --slot signature`（或 `export SBOMSIGN_KEY=sk`；`--slot` 省略時用 cosign 預設的 signature slot）。sbomsign 第 0 步先 `cosign public-key --sk` 確認卡在、指紋已登錄；沒插卡印 `YubiKey not present: <cosign 錯誤>` 並 exit 1（RQ6）。

### 驗收（等硬體到位）

- **AC6**：A 登錄、發版 → 對過渡鑰簽的正式證據 `--resign` → 過渡鑰標 revoked、發版 → `verify-release` 只拿舊 bundle 的副本被拒（key-revoked），含新 bundle 的通過。
- **AC7**：拔 A、插 B，`sbomsign … --key sk` 直接簽一個新 tag，`verify-release` 通過（B 早已登錄，不需改任何設定）。

## 13. 分支保護（補強 R4）

- GitHub：Settings → Rules → Rulesets → 目標分支 `sbom-evidence`：Restrict deletions、Block force pushes；bypass 只給 mac mini 推送用的帳號（它也只需要一般 push）。
- Bitbucket：Repository settings → Branch restrictions → `sbom-evidence`：Prevent deletion、Prevent rewriting history；Write access 只給 mac mini 推送用的帳號。
- 簽章擋得住竄改、擋不住刪除；被刪時以本機紀錄（gate_sha256、evidence_commit）比對並以 `--out` 本機副本重新發布。

## 14. 本機紀錄（RQ7）

`~/.sbom-cicd/sbom-signing-log.jsonl` 每行一筆：

```json
{"time":"…","action":"sign","repo":"git@github.com:ivanlin/harness.git","sha":"…","tag":"v1.4.0","gate_sha256":"…","key_id":"interim-2026-10","key_fingerprint":"sha256:…","bundle":"gate.json.interim-2026-10.sigstore.json","evidence_branch":"sbom-evidence","evidence_commit":"…","toolkit_image":"…@sha256:…","toolkit_version":"1.2.0","result":"ok"}
```

重簽多 `"action":"resign","resign_of":"<舊keyid>"`；中止為 `"result":"aborted","stage":"…","reason":"…"`。定期檢查是否有自己沒做過的簽章（R1 的偵測手段）。

## 15. 退出碼

| 指令 | 0 | 1 | 2 |
|---|---|---|---|
| `sbomgate scan` | gate PASS | 工具／政策錯誤（如豁免過期） | gate FAIL（達門檻的 CVE） |
| `sbomgate verify-release` | 全部檢查 PASS | 任一 FAIL 或錯誤 | — |
| `sbomgate verify-toolkit` | 某把可用金鑰驗證通過 | 未釘 digest、無可用金鑰、驗證失敗、任何錯誤 | — |
| `sbomgate check-tools` | 六個工具與 tools.lock 全部相符 | 任一 MISMATCH／missing | — |
| `sbomsign` | 簽章（與發布）完成 | 任何失敗（載體不可用、驗證失敗、已發布過、push 失敗…），不留任何證據 | gate FAIL 且未加 `--sign-failed` |
| `scripts/consistency-compare.sh` | 元件集合相同 | 元件集合不同 | 用法錯誤／檔案無法讀取 |

## 16. 已接受的風險

- R1 mac mini 失陷等於簽章者失陷。靠 RQ7 本機紀錄偵測，靠 RQ15 撤銷補救。
- R2 過渡期內私鑰檔在 mac mini 上，失陷後可離線偽造，且無法靠拔鑰止血。只能靠 RQ15 換鑰與重簽。硬體到位是消除此風險的唯一方法。
- R3 離線驗證端有撤銷延遲，直到更新工具箱版本。
- R4 證據分支可被刪除或強制覆寫。簽章擋得住竄改，擋不住刪除，靠分支保護與本機紀錄補強。
