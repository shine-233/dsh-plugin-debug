# Source snapshot status

This is the current single-package publication release source tree. The public remote is
`https://github.com/shine-233/dsh-plugin-debug.git`, default branch `main`.

| Component | Files | Notes |
| --- | ---: | --- |
| packages/dsh-plugin-debug | 96 npm-pack entries | One combined runtime plugin plus Host-side diagnostics, recovery, Crash Guard, startup incident receipts, read-only plugin bisect planning, diagnostics-report diffing, static plugin preflight, dependency graph inspection, offline trace-loop and bounded trace-recursion analysis, observer-only task guardian and its status checker, bounded client breadcrumbs, Workbench and one-click launcher; the ten small, synthetic `tools/fixtures` inputs ship for reproducible trace/pointer/bisect/dependency/trace-loop/recursion tests, while fake runtimes and temporary Profiles are generated at test time |

The original provenance, debug-suite and one-click inputs were removed from the
projects tree after migration review and are not package dependencies. The
store directory was already absent and remains disabled. Repeat source/hash
comparison after any functional change; do not silently call this snapshot
current without that comparison.

The migration inventory is a historical review record rather than a copy of the
deleted source trees. Current-state proof is limited to the single package tree,
the exported entry points, the migration manifest and the regression suites; it
does not claim that a deleted source directory can be re-diffed in place.

Publication evidence is recorded separately in `RELEASE-MANIFEST.json`.
For the 0.8.1 release, both publication-boundary and fresh-clone verification
passed against source commit
`f74e06d8ce82d5c9d7b091e9ab000248e166f368`; the recorded UTC times are
`2026-08-16 06:26:43.6864902Z` and `2026-08-16 06:26:45.0077274Z`.

The previous publication baseline commit was
`202d4aa6369232a2dc852b5d4e898290efb7cf3b`. The 0.8.1 source commit above is
the commit recorded as `publishedCommit`; the later evidence commit only
records verification metadata and must not replace that source hash. Future
functional changes must create a new candidate source commit and repeat the
same fresh-clone and publication gates.
