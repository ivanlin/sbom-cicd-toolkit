# 新專案接入指南（照抄即可）

前提：專案是 git repo；本機有 Docker（或用 `install/native-install.sh` 裝原生版）。

## 1. 本機先跑一次（不改任何檔案）
```bash
docker volume create sbomgate-cache   # 第一次會下載 grype/trivy 弱點庫，之後重用
docker run --rm -v sbomgate-cache:/cache -v "$PWD:/src:ro" -v "$PWD/sbom-out:/out" \
  ghcr.io/ivanlin/sbom-cicd-toolkit:1.0.1 scan --source /src --name "$(basename "$PWD")" --out /out --fail-on CRITICAL
echo "exit=$?"            # 0 通過、2 閘門失敗、1 工具/政策錯誤
cat sbom-out/summary.md   # 元件數、CVE 統計、CRITICAL/HIGH 明細
```
產出容器映像的專案再多一步：
```bash
docker build -t app:local . && docker save app:local -o /tmp/app.tar
docker run --rm -v sbomgate-cache:/cache -v "$PWD:/src:ro" -v /tmp/app.tar:/in/app.tar:ro -v "$PWD/sbom-out:/out" \
  ghcr.io/ivanlin/sbom-cicd-toolkit:1.0.1 scan --source /src --image-tar /in/app.tar --name app --out /out --fail-on CRITICAL
```

## 2. 加入豁免檔（空的也要有，閘門才有地方留紀錄）
```bash
mkdir -p .sbom-cicd && curl -fsSL https://raw.githubusercontent.com/ivanlin/sbom-cicd-toolkit/v1.0.1/templates/allowlist.yaml -o .sbom-cicd/allowlist.yaml
echo "sbom-out/" >> .gitignore
```
每筆豁免必填 `vulnerability / reason / approved_by / approved_on / expires`；過期即 exit 1，不會靜默放行。豁免進 git，PR review 就是核准紀錄。

## 3. GitHub Actions
原始碼型專案（複製範本後只改 `name:`）：
```bash
mkdir -p .github/workflows
curl -fsSL https://raw.githubusercontent.com/ivanlin/sbom-cicd-toolkit/v1.0.1/templates/sbom-cicd.yml -o .github/workflows/sbom-cicd.yml
```
容器映像型專案改用 `templates/sbom-cicd-image.yml`，把 `docker build` 那一行換成自己的建置指令。
推上去後在 Actions 看 `sbom-cicd` run：Summary 頁有 summary.md，Artifacts 有 `sbom-cve-gate-<name>`（gate.json、SBOM、掃描 JSON）。

## 4. SSSF 專案：讓它成為 ADW 硬性節點
```bash
# 在已蓋章的 repo 根目錄，從最新的 sssf-xplat 補上模組（不覆蓋你已改好的 quality.py 其他區塊）
python3 /path/to/sssf-xplat/.claude/skills/sssf/scripts/install.py        # 新檔：adw_modules/supply_chain.py、adw_supply_chain.py、.sbom-cicd/allowlist.yaml
# 設定 adws/adw_sssf_config/sssf.config.yaml → defaults.supply_chain:（image / fail_on / source / image_tar）
just sbom "pre-release check"       # 單跑閘門；sdlc / simple-sdlc / build-test 鏈在 commit 前都會自動跑
```

## 5. 升版
把 `1.0.0` 換成新版本（workflow 的 `@v1.0.0`、`TOOLKIT` env、sssf.config.yaml 的 `image:`）。版本規則見 docs/RELEASING.md。
