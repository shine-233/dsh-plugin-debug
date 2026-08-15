# Source snapshot status

This is the published single-package source tree. The public remote is
`https://github.com/shine-233/dsh-plugin-debug.git`, default branch `main`.

| Component | Files | Notes |
| --- | ---: | --- |
| packages/dsh-plugin-debug | 75 npm-pack entries | One combined runtime plugin plus Host-side diagnostics, recovery, Crash Guard, Workbench and one-click launcher; the six small, synthetic `tools/fixtures` inputs ship for reproducible trace/pointer tests, while fake runtimes and temporary Profiles are generated at test time |

The original provenance, debug-suite and one-click inputs were removed from the
projects tree after migration review and are not package dependencies. The
store directory was already absent and remains disabled. Repeat source/hash
comparison after any functional change; do not silently call this snapshot
current without that comparison.

The publication baseline commit is
`c0512d0e8cf69ffc596233e4fba1836ec3923cfe`. A fresh clone has passed the same
package and publication checks before a later change is considered released.
