# Gate policy (v1)

| Item | Rule |
|---|---|
| Threshold | `--fail-on CRITICAL` (default). Any grype finding with severity >= threshold, after exemptions, fails the gate (exit 2). |
| Scanners | grype decides; trivy runs on the same SBOM as an independent cross-check and is recorded, never gates. |
| Scope | Source SBOM always; image SBOM when `--image-tar`/`--image` given. Both are gated together. |
| Exemptions | Only via `.sbom-cicd/allowlist.yaml` in the scanned repo (or `--allowlist`). Every entry needs `vulnerability`, `reason`, `approved_by`, `approved_on`, `expires`. |
| Expiry | An expired exemption is a POLICY ERROR (exit 1), not a silent re-enable. |
| Who may exempt | Whoever can merge to the repo's default branch — the allowlist lives in git, so the approval record is the commit + PR review. |
| Record | Every run writes `gate.json` with the exemptions applied and `grype_ignored_matches`. |
| Unknown severity | Reported, never counted. |
| Fixability | `--only-fixed` is opt-in: by default unfixed CRITICALs still fail (you can exempt them with an expiry). |
