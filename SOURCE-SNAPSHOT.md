# Source snapshot status

This is the current single-package publication candidate source tree. The public remote is
`https://github.com/shine-233/dsh-plugin-debug.git`, default branch `main`.

| Component | Files | Notes |
| --- | ---: | --- |
| packages/dsh-plugin-debug | 95 npm-pack entries | One combined runtime plugin plus Host-side diagnostics, recovery, Crash Guard, startup incident receipts, read-only plugin bisect planning, diagnostics-report diffing, static plugin preflight, dependency graph inspection, offline trace-loop and bounded trace-recursion analysis, observer-only task guardian and its status checker, bounded client breadcrumbs, Workbench and one-click launcher; the ten small, synthetic `tools/fixtures` inputs ship for reproducible trace/pointer/bisect/dependency/trace-loop/recursion tests, while fake runtimes and temporary Profiles are generated at test time |

The original provenance, debug-suite and one-click inputs were removed from the
projects tree after migration review and are not package dependencies. The
store directory was already absent and remains disabled. Repeat source/hash
comparison after any functional change; do not silently call this snapshot
current without that comparison.

The previous publication baseline commit was
`202d4aa6369232a2dc852b5d4e898290efb7cf3b`; the 0.8.0 candidate is currently
being revalidated locally and must receive a new commit hash after push. A
fresh clone must pass the same package and publication checks before this
candidate is called released.
