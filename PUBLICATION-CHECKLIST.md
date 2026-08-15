# Public release checklist

This checklist is the gate for the single combined DSH Debug Plugin. Do not
initialize Git, configure a remote or push until the user confirms the target
account, repository, visibility and copyright holder.

## Source and boundary

- [ ] `packages/dsh-plugin-debug` is the only public package and contains the runtime plus Host-side debug/launcher tools.
- [ ] The package retains runtime ID `dsh-plugin-debug` and version `0.4.0`.
- [ ] Crash Guard's fake runtime is generated only in a bounded temporary test directory; no independent fixture package is present.
- [ ] The plugin-store source and capability are absent from the candidate and have been removed locally.
- [ ] No `.dsh`, `.codex`, Profile state, logs, state, temporary directory, node_modules or coverage output is present.

## Metadata and licensing

- [x] Root and package MIT copyright holder is recorded as `shine-233`.
- [x] The public package manifest has a real `repository`, `bugs` and `homepage` field.
- [x] `RELEASE-MANIFEST.json` records owner `shine-233`, repository `dsh-plugin-debug`, public visibility and pre-publication status.
- [ ] Dependency licenses have been reviewed for the exact runtime lockfile.

## Verification

```powershell
Set-Location .\packages\dsh-plugin-debug
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHProvenanceIntegration.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
Pop-Location

Set-Location .
.\scripts\Verify-Publication.ps1
```

Classify any intentional fixture markers; never treat a green static check as
proof of a real production DSH or successful GitHub publication.

## GitHub gate

- [ ] Target GitHub owner, repository name and visibility are confirmed.
- [ ] A reviewed local first commit exists.
- [ ] Remote URL is explicitly confirmed before configuration.
- [ ] Push is performed only after staged contents are approved.
- [ ] A fresh clone passes the single-package tests and publication checks.
