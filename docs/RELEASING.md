# Versioning & releasing

**Version number** lives in `VERSION` (SemVer) and is the image tag. Rules:
- MAJOR: gate semantics change (threshold meaning, the meaning of exit 0 / 2, gate.json schema break, allowlist format).
- MINOR also covers splitting the catch-all error exit 1 into dedicated codes (1.3.0): exit 0 and 2 keep their meaning, every new code is non-zero exactly where 1 used to be, so a caller that only checks `== 0` / `== 2` / `!= 0` behaves the same.
- MINOR: a tool in `tools.lock` is bumped, a new flag/output is added (backwards compatible).
- PATCH: fixes with no behaviour change for a passing/failing verdict.
Image tags published per release: `X.Y.Z`, `sha-<git sha>`, and `latest` (tags only). Since 1.2.0 consumers pin the **index digest** (`ghcr.io/ivanlin/sbom-cicd-toolkit@sha256:…`, never a tag, never `latest`), verify it with `verify-toolkit`, and bump deliberately.

**Cut a release**
```bash
# 1. bump
vi tools.lock            # if a tool moves: new version + archive sha256 for all 5 platforms, then
scripts/lock-bin-hashes.sh   # regenerate the *_BIN_SHA256_* table (sha256 of the extracted executables, used by check-tools)
vi policy/trusted-keys.yaml  # key added / extended / revoked? (docs/SIGNING.md) — the image bakes this file in
echo 1.2.0 > VERSION
git commit -am "release: 1.2.0 — …"
# 2. tag = v + VERSION (release.yml refuses a mismatch)
git tag v1.2.0 && git push origin main v1.2.0
# 3. release.yml: buildx linux/amd64+arm64 → ghcr push → imagetools inspect (per-arch digests) →
#    self-scan with the just-built image (gate must PASS) → check-tools + tools (amd64, arm64) →
#    trusted-keys.yaml baked into the image == policy/ copy → keyless cosign sign + attest (D6) →
#    KEY-SIGNING-TODO.md → native bundle → GitHub Release (assets include trusted-keys.yaml,
#    check-tools.txt, tools.json, KEY-SIGNING-TODO.md). No private key is used in CI (D2).
# 4. key signature — operator, on the mac mini, from a checkout of the tag (after the GitHub Release exists:
#    the script downloads the self-scan SBOM from the release assets for the attestation)
git checkout v1.2.0
scripts/sign-toolkit-image.sh 1.2.0            # cosign sign --key + cosign attest --key --type cyclonedx, tlog off, then verify-toolkit
# 5. verify both signatures
D="$(docker buildx imagetools inspect ghcr.io/ivanlin/sbom-cicd-toolkit:1.2.1 --format '{{json .Manifest}}' | jq -r .digest)"
TK="ghcr.io/ivanlin/sbom-cicd-toolkit@$D"
docker run --rm "$TK" verify-toolkit --image "$TK"                       # key path (consumers' default)
cosign verify "$TK" \
  --certificate-identity-regexp '^https://github.com/ivanlin/sbom-cicd-toolkit/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com  # keyless path
# 6. publish the digest: replace the `@sha256:<fill-from-release>` placeholders on main (templates/*.yml,
#    .github/workflows/scan.yml default) and tell consumers the pinned ref.
```
Why a placeholder in the tagged files: a file inside tag vX.Y.Z cannot contain the digest of the image that is built *from* that tag. Consumers therefore always pass the digest themselves (`toolkit_image:` input of the reusable workflow, `TOOLKIT` in the image / Bitbucket templates); the reusable workflow refuses the placeholder and tag-only refs.

**Upgrading consumers**: only after step 4 (`verify-toolkit` exits 0), change `uses: ivanlin/sbom-cicd-toolkit/.github/workflows/scan.yml@vX.Y.Z` + `toolkit_image:` (or the `TOOLKIT` env), `TOOLKIT=` / `TOOLKIT_TAG=` in `bitbucket-pipelines.yml`, and `defaults.supply_chain.image` (digest-pinned) in each SSSF repo's `adws/adw_sssf_config/sssf.config.yaml`.

## Changelog
- **1.3.0** (2026-10-17) — dedicated exit codes (README table, `sbomgate exit-codes [--json]`): 3 UNAVAILABLE (vulnerability DB download / registry / network — classified only from unambiguous network markers on non-WARN lines, plus grype's "DB would not load" + WARN-level refresh failure pair), 4 UNTRUSTED (verify-toolkit signature mismatch or no usable key, check-tools mismatch, key-status not usable, verify-release with any failed check other than the gate result), 5 POLICY (allowlist incomplete/expired, trusted-keys file missing/malformed, bad `--fail-on`), 64 USAGE (arguments, input paths); 1 remains the catch-all; `verify-release` whose only failed check is a signed FAIL result exits 2. `scan`: a scanner that cannot get its DB no longer aborts the run — grype (the counting scanner) and trivy each record `unavailable[] {scanner, kind, endpoints, detail}` in gate.json, findings from whatever ran still decide (count ≥ 1 → exit 2), otherwise `result: "UNAVAILABLE"`, exit 3, and `counted_at_or_above_threshold` is `null` when grype itself did not run. Every error line carries its class (`ERROR [unavailable]: …`). grype runs without `-q` (with `-q` a failure printed nothing at all), syft/grype app-update checks are off (offline they logged a network ERROR unrelated to the scan), and a rerun into the same `--out` first removes the previous gate.json / scan files. tools.lock unchanged (same binaries as 1.2.1).
- **1.2.1** (2026-10-16) — release/CI fixes only; gate behaviour, gate.json schema 2 and the signing commands are identical to 1.2.0. (1) `release.yml`: the per-architecture `check-tools`/`tools` evidence runs each arch by its own manifest digest — pulling the index digest twice with different `--platform` values fails with `cannot overwrite digest` (this is why the 1.2.0 release run failed after the image was already pushed; `ghcr.io/ivanlin/sbom-cicd-toolkit:1.2.0` exists but has no GitHub Release and was never key-signed — do not pin it). (2) `install/native-install.sh`: GNU `sha256sum` prefixes its output with `\` when the file name contains a backslash (Git Bash on Windows), which made every binary-hash check fail there; the prefix is now stripped. (3) `matrix.yml`: the Linux native job installs `libpcsclite1` first, because the pinned Linux cosign is the PIV-enabled variant (native Linux hosts need libpcsclite; the image ships `pcsc-lite`).
- **1.2.0** (2026-10) — signing & verification, first phase GitHub + Bitbucket (docs/SIGNING.md).
  - `gate.json` **schema 2** — *additive*: every 1.x field is kept; new `source {remote_url, git_sha, git_ref}` and `artifacts[] {path, sha256, size}` (every file under `sbom/`, `scan/` plus the `gate/` inputs, paths relative to the out dir). New scan flags `--source-url` / `--source-ref`; the container still reads no provider variables (RQ13). Readers that check `schema == 1` must accept 2.
  - New `sbomgate verify-release` (offline: artifacts hashes, `--expect-sha`, any valid bundle from a usable trusted key, `result == PASS`; `--skip-signature`, `--at`, `--json`), `verify-toolkit` (image must be `@sha256:`-pinned; cosign key verification against the trusted keys), `check-tools` (resolved syft/grype/trivy/yq/jq/cosign vs the new `*_BIN_SHA256_<os>_<arch>` table in `tools.lock`, regenerated by `scripts/lock-bin-hashes.sh`), `key-entry` (prints a trusted-keys entry for a public key). `sbomgate tools` reports cosign.
  - New host-side `bin/sbomsign <repo> <rev>` and `--resign <tag>` (mac mini only, D2): carrier check → clone → verified-toolkit scan → pre-sign check → `cosign sign-blob` (no Rekor) → post-sign verify → orphan branch `sbom-evidence/<tag>/` → `~/.sbom-cicd/sbom-signing-log.jsonl`. Atomic: nothing is left on failure.
  - New `policy/trusted-keys.yaml` (shipped with `keys: []` + schema; baked into the image at `/opt/sbom-cicd-toolkit/trusted-keys.yaml` and into native installs; uploaded as a release asset). Revocation propagates by releasing the toolkit (R3).
  - cosign **3.1.3** pinned in `tools.lock` (sha256 per platform; linux uses the `pivkey-pkcs11key` build) and installed in the image and by both native installers (RQ18).
  - Templates for **Bitbucket Pipelines** (`templates/bitbucket-pipelines.yml`, `-image.yml`, size 2x + docker 3072 MB, `custom: fixtures`); GitHub templates and reusable `scan.yml` now take a digest-pinned `toolkit_image` and run `verify-toolkit` before scanning. `scripts/consistency-compare.sh` for the RQ14 GitHub-vs-Bitbucket component-set comparison.
  - CI: `release.yml` keeps the keyless signature (D6) and adds check-tools/tools evidence, a trusted-keys consistency check and `KEY-SIGNING-TODO.md` for the operator (`scripts/sign-toolkit-image.sh`); `matrix.yml` runs `check-tools` and a keyless `verify-release --skip-signature` smoke.
- **1.1.0** (2026-10-15) — policy: default threshold is now `--fail-on HIGH` everywhere (CLI default, reusable `scan.yml` input default, templates, fixtures). Project floor is HIGH: CRITICAL findings are fixed, not exempted; the SSSF gate (sssf-xplat) rejects `CRITICAL`/`none` in its config and runs a bounded repair loop (`max_repairs` 1..3, default 1). Tool bumps: yq 4.52.5→4.54.1, jq 1.8.1→1.8.2 (fixes CVE-2026-49839). The release self-scan of the toolkit image itself stays at `--fail-on CRITICAL` on purpose: its HIGHs are Go stdlib / x/net findings compiled into the upstream syft/grype/trivy release binaries, which we pin by sha256 and cannot rebuild; this is a documented exception, not the project default.
- **1.0.2** (2026-10-15) — reusable `scan.yml`: drop the `permissions:` block and the GHCR login (a called workflow cannot request `packages: read` when the caller grants only `contents: read` → `startup_failure`; the image is public anyway). `sbomgate` fails loudly when grype/trivy exit non-zero or write an empty file (seen on a Windows host with a full disk). Image content identical to 1.0.1 (same tools.lock).
- **1.0.1** (2026-10-15) — Windows native: pass `C:\` paths to syft/grype/trivy via cygpath; `native-install.ps1` `${dest}` parse fix; reusable `scan.yml` rewritten in block YAML (the 1.0.0 tag's copy fails GitHub's parser, so consumers must reference `@v1.0.1`). Image content otherwise identical to 1.0.0 (same tools.lock).
- **1.0.0** (2026-10-15) — first release: syft 1.54.1, grype 0.120.1, trivy 0.76.0, yq 4.52.5, jq 1.8.1 on wolfi-base; linux/amd64 + linux/arm64; keyless cosign signature + CycloneDX attestation.
