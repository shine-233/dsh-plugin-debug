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
tree after this review. None is a package dependency. The disabled
`dsh-plugin-store` directory was already absent and was not recreated.

## Intentional name changes and exclusions

The migration review used a function-name inventory while the source inputs
were available. It recorded each provenance/debug-suite function as retained
under the same name or as an exported/shared helper, and recorded the ten
one-click names that were intentionally renamed or removed below. Because the
old source directories are no longer present, this document is an audit record,
not a claim that a fresh source-to-source diff can still be reproduced from the
current projects tree.

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

This manifest records the migration boundary, not a permanent test result.
The current worktree has changed since the historical baseline, so the
following commands are required before claiming publication:

```text
Verify-Publication.ps1  # run from a clean candidate tree, before npm ci
npm ci --ignore-scripts
npm test
npm run check
Test-DSHStandalone.ps1
Test-DSHPluginIntegration.ps1 -SkipCompatibility
fresh clone verification of the pushed source commit
```

Each command must retain its real exit code. Crash Guard's intentionally
failing runtime must remain inside a bounded temporary directory; no standalone
fixture package, raw Tool payload, `.env` content or store source may enter the
candidate or npm tarball. This report does not claim real production DSH or
GitHub runtime verification until the fresh-clone and remote-hash gates are
recorded.
