# 新專案接入指南（照抄即可）

前提：專案是 git repo；本機有 Docker（或用 `install/native-install.sh` 裝原生版）。

工具箱映像一律**以 digest 釘版**（1.2.0 起），不要只寫 tag。取得某版的 digest：
```bash
docker buildx imagetools inspect ghcr.io/ivanlin/sbom-cicd-toolkit:1.2.0   # 取 "Digest:" 那行（index digest）
TK="ghcr.io/ivanlin/sbom-cicd-toolkit@sha256:<fill-from-release>"         # 下文都用 $TK
```
只在該版的 key 簽章完成後才換 digest：`docker run --rm "$TK" verify-toolkit --image "$TK"` 要 exit 0（見 docs/RELEASING.md、docs/SIGNING.md）。

## 1. 本機先跑一次（不改任何檔案）
```bash
docker volume create sbomgate-cache   # 第一次會下載 grype/trivy 弱點庫，之後重用
docker run --rm "$TK" verify-toolkit --image "$TK"    # 工具箱映像驗簽，0 才往下
docker run --rm -v sbomgate-cache:/cache -v "$PWD:/src:ro" -v "$PWD/sbom-out:/out" \
  "$TK" scan --source /src --name "$(basename "$PWD")" --out /out --fail-on HIGH
echo "exit=$?"            # 0 通過、2 閘門失敗、1 工具/政策/驗證錯誤
cat sbom-out/summary.md   # 元件數、CVE 統計、CRITICAL/HIGH 明細
```
產出容器映像的專案再多一步：
```bash
docker build -t app:local . && docker save app:local -o /tmp/app.tar
docker run --rm -v sbomgate-cache:/cache -v "$PWD:/src:ro" -v /tmp/app.tar:/in/app.tar:ro -v "$PWD/sbom-out:/out" \
  "$TK" scan --source /src --image-tar /in/app.tar --name app --out /out --fail-on HIGH
```
CI 會另外傳 `--source-url <repo URL> --source-ref <commit>`，寫進 gate.json 的 `source`（schema 2）；本機不傳時取 `git remote get-url origin`。

## 2. 加入豁免檔（空的也要有，閘門才有地方留紀錄）
```bash
mkdir -p .sbom-cicd && curl -fsSL https://raw.githubusercontent.com/ivanlin/sbom-cicd-toolkit/v1.2.0/templates/allowlist.yaml -o .sbom-cicd/allowlist.yaml
echo "sbom-out/" >> .gitignore
```
每筆豁免必填 `vulnerability / reason / approved_by / approved_on / expires`；過期即 exit 1，不會靜默放行。豁免進 git，PR review 就是核准紀錄。

## 3. GitHub Actions
原始碼型專案（複製範本後改 `name:` 並把 `toolkit_image:` 換成 release 的 digest）：
```bash
mkdir -p .github/workflows
curl -fsSL https://raw.githubusercontent.com/ivanlin/sbom-cicd-toolkit/v1.2.0/templates/sbom-cicd.yml -o .github/workflows/sbom-cicd.yml
```
容器映像型專案改用 `templates/sbom-cicd-image.yml`（改 `TOOLKIT:` 的 digest），把 `docker build` 那一行換成自己的建置指令。
流程：以 digest 拉映像 → `verify-toolkit`（驗簽失敗即停，exit 1）→ 掃描 → 上傳產物。`toolkit_image` 仍是 `<fill-from-release>` 佔位字串或只寫 tag 時，workflow 會直接失敗並提示。
推上去後在 Actions 看 `sbom-cicd` run：Summary 頁有 summary.md，Artifacts 有 `sbom-cve-gate-<name>`（gate.json、SBOM、掃描 JSON）。

## 4. Bitbucket Pipelines
```bash
curl -fsSL https://raw.githubusercontent.com/ivanlin/sbom-cicd-toolkit/v1.2.0/templates/bitbucket-pipelines.yml -o bitbucket-pipelines.yml
# 容器映像型專案改抓 templates/bitbucket-pipelines-image.yml（同樣存成 repo 根目錄的 bitbucket-pipelines.yml）
```
1. 改檔內 `TOOLKIT=` 的 digest、`NAME=`（映像型另改 `docker build` 那行）。repo 已有 `bitbucket-pipelines.yml` 時，把 `definitions` 與 step 併進去即可。
2. Repository settings → Pipelines → Settings → **Enable Pipelines**，commit 並 push。
3. 結果：Pipelines → 該次 run → step log 結尾有 summary.md；**Artifacts** 分頁有 `sbom-out/`（gate.json、SBOM、掃描 JSON）。Bitbucket 的 artifacts 保留 14 天，要長期留存請走 docs/SIGNING.md 的證據分支。
4. 資源：範本已設 `size: 2x` 與 docker service `memory: 3072`（1x step 只有 4096 MB、docker service 預設 1024 MB 不夠掃描用）。2x 會用掉兩倍 build minutes。
5. Bitbucket 只允許掛載 `$BITBUCKET_CLONE_DIR` 以下的目錄，所以輸出放在 clone 內的 `sbom-out/`，並以 `.git/info/exclude` 排除，不會被當成原始碼掃進 SBOM。
6. 一致性測試（RQ14）：Pipelines → Run pipeline → `custom: fixtures`，在 Bitbucket 上跑工具箱自帶的兩個 fixtures；把 Artifacts 裡的 `sbom-fixtures/clean/sbom/clean-app.source.cdx.json` 與 GitHub `platform-matrix` 的同名檔比對：
   ```bash
   scripts/consistency-compare.sh github/clean-app.source.cdx.json bitbucket/clean-app.source.cdx.json   # 0 = 元件集合相同
   ```
   只比對元件集合；漏洞結果與檔案雜湊本來就可能不同，不比。

GitHub 與 Bitbucket 的範本只做轉接：判定全在容器內，容器不讀任何 provider 專屬環境變數（commit 與 remote URL 以 `--source-ref` / `--source-url` 參數傳入）。

## 5. SSSF 專案：讓它成為 ADW 硬性節點
```bash
# 在已蓋章的 repo 根目錄，從最新的 sssf-xplat 補上模組（不覆蓋你已改好的 quality.py 其他區塊）
python3 /path/to/sssf-xplat/.claude/skills/sssf/scripts/install.py        # 新檔：adw_modules/supply_chain.py、adw_supply_chain.py、.sbom-cicd/allowlist.yaml
# 設定 adws/adw_sssf_config/sssf.config.yaml → defaults.supply_chain:（image 用 @sha256 digest / fail_on / source / image_tar）
just sbom "pre-release check"       # 單跑閘門；sdlc / simple-sdlc / build-test 鏈在 commit 前都會自動跑
```

## 6. Release 簽章（正式出貨）
CI 裡的掃描是給開發者看的回饋；**正式出貨的證據由 mac mini 簽章**（CI 不簽，D2）：
```bash
sbomsign git@github.com:ivanlin/harness.git v1.4.0 --image "$TK"          # Bitbucket 同指令，換 URL
```
證據推到產品 repo 的 `sbom-evidence` 分支 `<tag>/`，任何人可離線驗證：`sbomgate verify-release --bundle-dir <tag>/ --expect-sha <commit>`。金鑰產生、登錄、輪替、YubiKey、驗證細節見 **docs/SIGNING.md**。

## 7. 升版
把舊 digest 換成新版的 digest：GitHub workflow 的 `uses: …/scan.yml@vX.Y.Z` 與 `toolkit_image:`（或 image 範本的 `TOOLKIT`）、`bitbucket-pipelines.yml` 的 `TOOLKIT=` 與 fixtures 的 `TOOLKIT_TAG=`、sssf.config.yaml 的 `image:`。換之前先跑一次 `verify-toolkit`。版本規則見 docs/RELEASING.md。
