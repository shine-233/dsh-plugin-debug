# Public release checklist

This checklist is the gate for the single combined DSH Debug Plugin. The first
public release is `shine-233/dsh-plugin-debug` on `main`; repeat this checklist
for every later version.

## Source and boundary

- [x] `packages/dsh-plugin-debug` is the only public package and contains the runtime plus Host-side debug/launcher tools.
- [x] The package retains runtime ID `dsh-plugin-debug` and candidate version `0.8.2`.
- [x] Crash Guard's fake runtime is generated only in a bounded temporary test directory; no independent fixture package is present.
- [x] Startup incident receipts and the read-only plugin bisect plan are covered by published tests and contain no raw payloads or automatic Profile mutation.
- [x] Startup health fail-closes unresolved or unavailable plugin failures: safe third-party mappings may be quarantined once, while core/unknown/ambiguous failures produce a `degraded` receipt without arbitrary disable or a second restart.
- [x] Diagnostics-report diffing is covered by a Windows PowerShell regression; sensitive or invalid inputs fail closed to `MANUAL_REVIEW`/`FAIL`.
- [x] Static plugin preflight is covered by a Windows PowerShell regression; it is offline/read-only, never executes plugin code, and routes dynamic access to `MANUAL_REVIEW`.
- [x] Dependency graph inspection is covered by a Windows PowerShell regression; missing packages, cycles and unreferenced local packages fail closed without install or execution.
- [x] Offline trace-loop analysis is covered by a Windows PowerShell regression; repeated metadata windows are reported without runtime blocking, Session creation or Profile mutation.
- [x] Offline trace-recursion analysis is covered by a Windows PowerShell regression; bounded lifecycle depth is reported without returning agent IDs, Session IDs or payloads.
- [x] The observer-only task guardian is covered by Node regressions for loop/recursion detection, redaction, bounded event state and non-termination behavior.
- [x] The guardian status checker has offline idle/busy fixtures and uses exit code 2 for busy, without performing restart or termination actions.
- [x] The client breadcrumb ring buffer is bounded at 80 entries, reports dropped entries, and is covered by a redaction regression test.
- [x] The diagnostics-diff action compares only bounded metadata and routes sensitive inputs to `MANUAL_REVIEW`.
- [x] The plugin-store source and capability are absent from the candidate and have been removed locally.
- [x] No `.dsh`, `.codex`, Profile state, logs, state, temporary directory, node_modules or coverage output is present.
- [x] Recovery regression proves sensitive files such as `.env` are recorded as excluded and are never copied or restored.
- [x] Published trace fixtures contain metadata only: no raw Tool arguments, result bodies, credentials or dangerous command text.
- [x] Guard API rejects non-loopback BaseUrl values unless an explicit host allowlist is configured.

## Metadata and licensing

- [x] Root and package MIT copyright holder is recorded as `shine-233`.
- [x] The public package manifest has a real `repository`, `bugs` and `homepage` field.
- [x] `RELEASE-MANIFEST.json` records the release owner, repository and public visibility, with evidence-backed `publicationVerifierPassedAt`/`freshCloneVerifiedAt` timestamps.
- [x] Dependency license fields were inventoried against the exact pinned runtime lockfile; this is not legal advice.

## Verification

```powershell
# Start from the candidate repository root. Verify before npm ci because the
# verifier intentionally rejects generated node_modules/state/log directories.
Set-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1

Push-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHPluginIntegration.ps1 -SkipCompatibility
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
.\tools\Test-DSHBisect.ps1
.\tools\Test-DSHDiagnosticsDiff.ps1
.\tools\Test-DSHPreflight.ps1
.\tools\Test-DSHDependencyGraph.ps1
.\tools\Test-DSHTraceLoop.ps1
.\tools\Test-DSHTraceRecursion.ps1
.\tools\Test-DSHGuardianStatus.ps1
.\tools\Test-DSHPluginIntegration.ps1  # compatibility wrapper; the earlier -SkipCompatibility run is the canonical contract path
.\tools\Test-DSHGuard.ps1
.\tools\Test-DSHPluginHealth.ps1
.\tools\Test-DSHPluginState.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHPointerBrowser.ps1  # optional; exit 2 means browser runtime unavailable
Pop-Location
```

After dependency-backed checks, remove only the generated dependency folders
from this candidate checkout, or use a clean/fresh clone for the final boundary
check. Then run `scripts\Verify-Publication.ps1` again from that clean tree.
Classify any intentional fixture markers; never treat a green static check as
proof of a real production DSH or successful GitHub publication.

## GitHub gate

- [x] Target GitHub owner, repository name and visibility are confirmed.
- [x] A reviewed local first commit exists.
- [x] Remote URL is explicitly confirmed before configuration.
- [x] Push is performed only after staged contents are approved.
- [ ] A fresh clone passes the single-package tests and publication checks for the `0.8.2` candidate; source SHA and evidence are filled only after the remote gates pass.

## Current 0.8.2 release evidence

- Candidate source commit pushed to `origin/main`: pending.
- GitHub Actions CI, CodeQL and `Fresh clone publication gate`: pending for
  the candidate source commit.
- Fresh-clone standalone suite: pending; the local Windows PowerShell proof
  before push is `result=PASS`, `filesChecked=59`,
  `powershellFilesParsed=55`, `fixtureChecks=51`.
- Root and fresh-clone `Verify-Publication.ps1`: pending for the candidate;
  the expected package boundary remains 96 files with the store removed.
- After those gates pass, update this section and `RELEASE-MANIFEST.json` in
  a separate evidence commit. Keep the previous `0.8.1` evidence in git
  history rather than copying it into the new release record.
