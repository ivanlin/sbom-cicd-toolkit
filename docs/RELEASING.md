# Versioning & releasing

**Version number** lives in `VERSION` (SemVer) and is the image tag. Rules:
- MAJOR: gate semantics change (threshold meaning, exit codes, gate.json schema, allowlist format).
- MINOR: a tool in `tools.lock` is bumped, a new flag/output is added (backwards compatible).
- PATCH: fixes with no behaviour change for a passing/failing verdict.
Image tags published per release: `X.Y.Z`, `sha-<git sha>`, and `latest` (tags only). Consumers pin `X.Y.Z` (never `latest`) and bump deliberately.

**Cut a release**
```bash
# 1. bump
vi tools.lock            # if a tool moves: new version + sha256 for all 5 platform files
echo 1.1.0 > VERSION
git commit -am "release: 1.1.0 — bump grype to 0.121.0"
# 2. tag = v + VERSION (release.yml refuses a mismatch)
git tag v1.1.0 && git push origin main v1.1.0
# 3. release.yml: buildx linux/amd64+arm64 → ghcr push → imagetools inspect (per-arch digests) →
#    self-scan with the just-built image (gate must PASS) → cosign sign + attest → GitHub Release
# 4. verify
docker buildx imagetools inspect ghcr.io/ivanlin/sbom-cicd-toolkit:1.1.0
cosign verify ghcr.io/ivanlin/sbom-cicd-toolkit:1.1.0 \
  --certificate-identity-regexp '^https://github.com/ivanlin/sbom-cicd-toolkit/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
**Upgrading consumers**: change the tag in `uses: ivanlin/sbom-cicd-toolkit/.github/workflows/scan.yml@vX.Y.Z` (or the `TOOLKIT` env), and `defaults.supply_chain.image` in each SSSF repo's `adws/adw_sssf_config/sssf.config.yaml`.

## Changelog
- **1.1.0** (2026-10-15) — policy: default threshold is now `--fail-on HIGH` everywhere (CLI default, reusable `scan.yml` input default, templates, fixtures). Project floor is HIGH: CRITICAL findings are fixed, not exempted; the SSSF gate (sssf-xplat) rejects `CRITICAL`/`none` in its config and runs a bounded repair loop (`max_repairs` 1..3, default 1). Tool bumps: yq 4.52.5→4.54.1, jq 1.8.1→1.8.2 (fixes CVE-2026-49839). The release self-scan of the toolkit image itself stays at `--fail-on CRITICAL` on purpose: its HIGHs are Go stdlib / x/net findings compiled into the upstream syft/grype/trivy release binaries, which we pin by sha256 and cannot rebuild; this is a documented exception, not the project default.
- **1.0.2** (2026-10-15) — reusable `scan.yml`: drop the `permissions:` block and the GHCR login (a called workflow cannot request `packages: read` when the caller grants only `contents: read` → `startup_failure`; the image is public anyway). `sbomgate` fails loudly when grype/trivy exit non-zero or write an empty file (seen on a Windows host with a full disk). Image content identical to 1.0.1 (same tools.lock).
- **1.0.1** (2026-10-15) — Windows native: pass `C:\` paths to syft/grype/trivy via cygpath; `native-install.ps1` `${dest}` parse fix; reusable `scan.yml` rewritten in block YAML (the 1.0.0 tag's copy fails GitHub's parser, so consumers must reference `@v1.0.1`). Image content otherwise identical to 1.0.0 (same tools.lock).
- **1.0.0** (2026-10-15) — first release: syft 1.54.1, grype 0.120.1, trivy 0.76.0, yq 4.52.5, jq 1.8.1 on wolfi-base; linux/amd64 + linux/arm64; keyless cosign signature + CycloneDX attestation.
