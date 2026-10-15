# Gate policy (v1)

| Item | Rule |
|---|---|
| Threshold | `--fail-on HIGH` (default since 1.1.0). Any grype finding with severity >= threshold, after exemptions, fails the gate (exit 2). Policy floor for projects: at least HIGH; CRITICAL findings are fixed, never exempted. The SSSF gate rejects `CRITICAL` and `none` in its config. The toolkit's own release self-scan is the one documented exception and runs at CRITICAL (its HIGHs live inside upstream scanner binaries, see RELEASING.md). |
| Scanners | grype decides; trivy runs on the same SBOM as an independent cross-check and is recorded, never gates. |
| Scope | Source SBOM always; image SBOM when `--image-tar`/`--image` given. Both are gated together. |
| Exemptions | Only via `.sbom-cicd/allowlist.yaml` in the scanned repo (or `--allowlist`). Every entry needs `vulnerability`, `reason`, `approved_by`, `approved_on`, `expires`. |
| Expiry | An expired exemption is a POLICY ERROR (exit 1), not a silent re-enable. |
| Who may exempt | Whoever can merge to the repo's default branch — the allowlist lives in git, so the approval record is the commit + PR review. |
| Record | Every run writes `gate.json` with the exemptions applied and `grype_ignored_matches`. |
| Unknown severity | Reported, never counted. |
| Fixability | `--only-fixed` is opt-in: by default unfixed findings at or above the threshold still fail (exempt them with an expiry, or fix the base image). |
