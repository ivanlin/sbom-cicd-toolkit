# sbom-cicd-toolkit

One versioned tool, one command, same result everywhere: **SBOM (CycloneDX 1.7 + SPDX 2.3) → CVE scan (grype, cross-checked by trivy) → policy gate → evidence**.

- Distributed as a multi-arch container image (`linux/amd64`, `linux/arm64`): `ghcr.io/ivanlin/sbom-cicd-toolkit:<version>`
- Same pinned tool versions natively on macOS / Linux / Windows via `install/native-install.sh` (`.ps1`) — all read `tools.lock`
- Scans itself on every release (`.github/workflows/release.yml`), signs the image keyless with cosign and attests its own SBOM
- Hard check node in SSSF (`sssf-xplat` → `adws/adw_modules/supply_chain.py`): a chain cannot commit code while the gate is red

```
docker run --rm -v sbomgate-cache:/cache -v "$PWD:/src:ro" -v "$PWD/sbom-out:/out" \
  ghcr.io/ivanlin/sbom-cicd-toolkit:1.0.2 scan --source /src --name my-app --out /out --fail-on CRITICAL
# exit 0 = PASS · 2 = FAIL (CVE at/above threshold) · 1 = tool/policy error
```

| Path | What |
|---|---|
| `bin/sbomgate` | the CLI (bash 3.2-compatible; runs in the image and natively) |
| `tools.lock` | pinned versions + sha256 for syft, grype, trivy, yq, jq (+ base image digest) |
| `Dockerfile` | multi-arch image; downloads from `tools.lock`, verifies checksums |
| `install/` | native installers (bash for macOS/Linux/Git-Bash, PowerShell for Windows) |
| `policy/gate-policy.md` | the gate rules; `templates/allowlist.yaml` the exemption file format |
| `templates/sbom-cicd*.yml` | drop-in GitHub workflows for consumer repos |
| `.github/workflows/scan.yml` | reusable workflow (`workflow_call`) consumers reference by tag |
| `.github/workflows/release.yml` | build → push → self-scan → cosign → GitHub Release |
| `.github/workflows/matrix.yml` | platform × arch verification with two fixtures (`examples/`) |
| `docs/ONBOARDING.md` | copy-paste steps for a new project |
| `docs/RELEASING.md` | version rules and how to cut a release |

Outputs per run (`--out`): `gate.json` (machine verdict + counts + exemptions + tool versions), `summary.md`, `sbom/<name>.{source,image}.{cdx,spdx}.json`, `scan/grype.*.json`, `scan/trivy.*.json`, `sbomgate.log`.
