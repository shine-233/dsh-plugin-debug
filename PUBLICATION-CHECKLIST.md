# Public release checklist

This checklist is the gate for the single combined DSH Debug Plugin. The first
public release is `shine-233/dsh-plugin-debug` on `main`; repeat this checklist
for every later version.

## Source and boundary

- [x] `packages/dsh-plugin-debug` is the only public package and contains the runtime plus Host-side debug/launcher tools.
- [x] The package retains runtime ID `dsh-plugin-debug` and version `0.4.0`.
- [x] Crash Guard's fake runtime is generated only in a bounded temporary test directory; no independent fixture package is present.
- [x] The plugin-store source and capability are absent from the candidate and have been removed locally.
- [x] No `.dsh`, `.codex`, Profile state, logs, state, temporary directory, node_modules or coverage output is present.

## Metadata and licensing

- [x] Root and package MIT copyright holder is recorded as `shine-233`.
- [x] The public package manifest has a real `repository`, `bugs` and `homepage` field.
- [x] `RELEASE-MANIFEST.json` records owner `shine-233`, repository `dsh-plugin-debug`, public visibility and published status.
- [x] Dependency license fields were inventoried against the exact pinned runtime lockfile; this is not legal advice.

## Verification

```powershell
Set-Location .\packages\dsh-plugin-debug
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHProvenanceIntegration.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
.\tools\Test-DSHGuard.ps1
.\tools\Test-DSHPluginHealth.ps1
.\tools\Test-DSHPluginState.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHPointerBrowser.ps1  # optional; exit 2 means browser runtime unavailable
Pop-Location

Set-Location .
.\scripts\Verify-Publication.ps1
```

Classify any intentional fixture markers; never treat a green static check as
proof of a real production DSH or successful GitHub publication.

## GitHub gate

- [x] Target GitHub owner, repository name and visibility are confirmed.
- [x] A reviewed local first commit exists.
- [x] Remote URL is explicitly confirmed before configuration.
- [x] Push is performed only after staged contents are approved.
- [x] A fresh clone passes the single-package tests and publication checks.
