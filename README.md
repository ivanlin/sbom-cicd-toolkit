# sbom-cicd-toolkit

One versioned tool, one command, same result everywhere: **SBOM (CycloneDX 1.7 + SPDX 2.3) → CVE scan (grype, cross-checked by trivy) → policy gate → evidence**.

- Distributed as a multi-arch container image (`linux/amd64`, `linux/arm64`): `ghcr.io/ivanlin/sbom-cicd-toolkit:<version>`
- Same pinned tool versions natively on macOS / Linux / Windows via `install/native-install.sh` (`.ps1`) — all read `tools.lock`
- Scans itself on every release (`.github/workflows/release.yml`), signs the image keyless with cosign and attests its own SBOM
- Hard check node in SSSF (`sssf-xplat` → `adws/adw_modules/supply_chain.py`): a chain cannot commit code while the gate is red
- **1.2.0 signing & verification** ([docs/SIGNING.md](docs/SIGNING.md)):
  - `gate.json` schema 2 binds the commit (`source.git_sha`) and every SBOM/scan file (`artifacts[]` sha256 + size)
  - `sbomsign <repo> <rev>` — mac-mini-only signing of `gate.json` (cosign, no Rekor), evidence on the orphan branch `sbom-evidence/<tag>/`, `--resign` for key rotation; same command for GitHub and Bitbucket URLs
  - `sbomgate verify-release` (offline: hashes + commit + any valid bundle from `policy/trusted-keys.yaml`), `verify-toolkit` (digest-pinned image signature), `check-tools` (binaries vs `tools.lock`), `key-entry`
  - cosign 3.1.3 pinned in `tools.lock`; YubiKey PIV supported (`--key sk`)
- **1.3.0 exit codes** — a caller branches on the code, never on text (`sbomgate exit-codes [--json]`):

  | code | name | meaning | typical caller action |
  |---|---|---|---|
  | 0 | PASS | gate / verification passed | continue |
  | 1 | ERROR | unclassified tool error (all errors were 1 before 1.3.0) | stop; read the log |
  | 2 | FINDINGS | CVEs at or above `--fail-on` (even if a cross-check scanner was unavailable); `verify-release`: a validly signed FAIL verdict | fix or exempt the CVEs |
  | 3 | UNAVAILABLE | an external resource could not be got: vulnerability DB download, registry, network; `gate.json` says `result: "UNAVAILABLE"` and lists `unavailable[]` (scanner, endpoints, detail) | re-run when reachable; never "fix" code |
  | 4 | UNTRUSTED | signature does not verify, no usable trusted key, binary differs from `tools.lock`, evidence tampered | stop; never degrade |
  | 5 | POLICY | allowlist entry incomplete or expired, trusted-keys file malformed, bad `--fail-on` | fix the policy file |
  | 64 | USAGE | unknown / missing argument, wrong input path | fix the invocation |
- CI templates for GitHub Actions **and Bitbucket Pipelines** — they only adapt; all judgment is inside the container

```
TK=ghcr.io/ivanlin/sbom-cicd-toolkit@sha256:<fill-from-release>   # docker buildx imagetools inspect ghcr.io/ivanlin/sbom-cicd-toolkit:1.3.0
docker run --rm "$TK" verify-toolkit --image "$TK"                 # signature of the pinned image (exit 0 = trusted)
docker run --rm -v sbomgate-cache:/cache -v "$PWD:/src:ro" -v "$PWD/sbom-out:/out" \
  "$TK" scan --source /src --name my-app --out /out --fail-on HIGH
# exit 0 = PASS · 2 = FAIL (CVE at/above threshold) · 3 unavailable · 4 untrusted · 5 policy · 64 usage · 1 other
```

| Path | What |
|---|---|
| `bin/sbomgate` | the CLI (bash 3.2-compatible; runs in the image and natively): `scan`, `verify-release`, `verify-toolkit`, `check-tools`, `key-entry`, `key-status`, `exit-codes`, `tools` |
| `bin/sbomsign` | host-side release signer (mac mini only): scan a commit, sign `gate.json`, publish to `sbom-evidence`, `--resign` |
| `tools.lock` | pinned versions + sha256 for syft, grype, trivy, yq, jq, cosign (archives + extracted binaries, + base image digest) |
| `policy/trusted-keys.yaml` | the public keys verifiers trust (expiry, revocation); baked into the image |
| `Dockerfile` | multi-arch image; downloads from `tools.lock`, verifies checksums |
| `install/` | native installers (bash for macOS/Linux/Git-Bash, PowerShell for Windows) |
| `policy/gate-policy.md` | the gate rules; `templates/allowlist.yaml` the exemption file format |
| `templates/sbom-cicd*.yml` | drop-in GitHub workflows for consumer repos |
| `templates/bitbucket-pipelines*.yml` | drop-in Bitbucket Pipelines (source / image variant, `custom: fixtures`) |
| `scripts/consistency-compare.sh` | RQ14: compare the component sets of two CycloneDX SBOMs (GitHub vs Bitbucket run) |
| `.github/workflows/scan.yml` | reusable workflow (`workflow_call`) consumers reference by tag |
| `.github/workflows/release.yml` | build → push → self-scan → check-tools → keyless cosign → GitHub Release (key signature: operator, `scripts/sign-toolkit-image.sh`) |
| `.github/workflows/matrix.yml` | platform × arch verification with two fixtures (`examples/`) |
| `docs/ONBOARDING.md` | copy-paste steps for a new project |
| `docs/RELEASING.md` | version rules, how to cut a release, changelog |
| `docs/SIGNING.md` | operator manual (zh-TW): keys, sbomsign, verification, rotation, YubiKey, accepted risks |

Outputs per run (`--out`): `gate.json` (schema 2: machine verdict + counts + exemptions + tool versions + `source` + `artifacts[]`), `summary.md`, `sbom/<name>.{source,image}.{cdx,spdx}.json`, `scan/grype.*.json`, `scan/trivy.*.json`, `sbomgate.log`.
