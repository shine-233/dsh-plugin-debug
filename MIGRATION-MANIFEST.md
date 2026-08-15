# DSH Plugin Migration Manifest

This file records the source-boundary decision for the single public package
`packages/dsh-plugin-debug`. It is an audit note, not a second runtime package.

## Source inputs

| Source directory | Current inventory | Disposition |
| --- | ---: | --- |
| `dsh-plugin-provenance` | 73 files / 894,732 bytes | Runtime and Host diagnostics merged into `dsh-plugin-debug` |
| `dsh-plugin-debug-suite` | 68 files / 877,203 bytes | Debug, recovery, trace, repair and evidence code merged into `dsh-plugin-debug` |
| `dsh-one-click` | 33,057 files including runtime/state; 42 source files after local-state filtering | Launcher, supervisor and Crash Guard code merged into `dsh-plugin-debug` |
| `dsh-plugin-store` | absent | Disabled for this release and excluded from the public package |

The three old source directories and the additional
`dsh-open-source-one-click-excluded` snapshot were removed from the projects
tree after this review and are recoverable only from the Windows Recycle Bin.
None is a package dependency. The disabled `dsh-plugin-store` directory was
already absent and was not recreated.

## Intentional name changes and exclusions

The migration was checked by function-name inventory. Every function from the
provenance and debug-suite source inputs is present in the combined source
under the same name or as an exported/shared helper. The old one-click source
has ten names that do not appear verbatim in the combined package:

| Old name | Decision |
| --- | --- |
| `Resolve-StandaloneDispatcher` | Replaced by the package-local dispatcher; the merged tool no longer depends on a sibling provenance directory |
| `Invoke-StandaloneHostAction` | Replaced by `DSH-Workbench.ps1` and its local named-argument dispatcher |
| `Test-ProvenanceBundleSource` | Replaced by `Resolve-ProvenanceBundle` and `Test-ProvenanceInstalled` |
| `Test-PluginStoreInstalled` | Intentionally removed with plugin-store |
| `Ensure-PluginStore` | Intentionally removed with plugin-store |
| `Assert-CrashGuard` | Test-only assertion helper renamed/replaced in the merged regression harness |
| `Invoke-LauncherChild` | Test-only process helper replaced by the current standalone/Crash Guard harness |
| `Invoke-StopChild` | Test-only process helper replaced by the current standalone/Crash Guard harness |
| `Remove-ReparseSafeTree` | Test-only cleanup helper replaced by bounded fixture cleanup in the current harness |
| `Assert-ProvenanceTest` | Test-only assertion helper replaced by `Assert-DebugIntegration` |

This is why a same-name file/function comparison is not the publication gate:
the canonical package must be self-contained and must not silently reinstall or
depend on the disabled plugin-store.

## Publication checks

The current candidate is verified by:

```text
npm run check                         24 passed
Test-DSHStandalone.ps1               PASS
Test-DSHProvenanceIntegration.ps1    PASS
Verify-Publication.ps1               PASS, 79 npm-pack entries
PowerShell parser                    47 files, 0 errors
```

Crash Guard's intentionally failing runtime is generated inside a bounded
temporary directory by the regression harness; no standalone fixture package
remains in the candidate or npm tarball. The migration report does not claim
real production DSH or GitHub runtime verification; those require a fresh
clone after publication.
