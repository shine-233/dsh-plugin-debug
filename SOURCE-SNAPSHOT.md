# Source snapshot status

This is the current single-package publication release source tree. The public remote is
`https://github.com/shine-233/dsh-plugin-debug.git`, default branch `main`.

| Component | Files | Notes |
| --- | ---: | --- |
| packages/dsh-plugin-debug | package file count pending final `npm pack` check (candidate) | One combined runtime plugin plus Host-side diagnostics, recovery, Crash Guard, startup incident receipts, read-only plugin bisect planning, diagnostics-report diffing, static plugin preflight, offline plugin repository health checks, read-only hotswap capability probing, deterministic metadata-only agent/session reports, dependency graph inspection, offline trace-loop and bounded trace-recursion analysis, observer-only task guardian and its status checker, bounded client breadcrumbs, Workbench and one-click launcher; the small, synthetic `tools/fixtures` inputs ship for reproducible trace/pointer/bisect/dependency/trace-loop/recursion tests, while fake runtimes and temporary Profiles are generated at test time |

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
The current working tree is a new candidate after the `0.8.2` baseline. It
has not been pushed or verified from an exact remote source commit, so its
publication fields remain `candidate`/`null`. Recompute the package count,
push a candidate source commit, re-read that remote SHA, and only then write
the evidence commit after a fresh-clone gate passes. Do not reuse the old
`0.8.2` timestamps or source hash for this candidate.

The remote currently advertises `v0.8.2`, but that historical release is not a
clean evidence baseline: `main` records published source commit
`b234e79dfe7b349568f7f3e3c63504979f0e74e0` while the `v0.8.2` tag/source
archive still contains candidate/null publication fields and its release body
has malformed literal newlines/control characters. Treat `0.8.2` as an
inconsistent historical snapshot, not as proof for this candidate. The older
local publication baseline was `0.8.1` at
`f74e06d8ce82d5c9d7b091e9ab000248e166f368`; future functional changes must
create a new candidate source commit and repeat the same fresh-clone and
publication gates.

## Current local evidence layers (0.8.3 candidate)

- Source and offline fixture checks cover implementation contracts and privacy
  boundaries. Fake/loopback supervisor checks cover bounded launch, attributed
  quarantine and unresolved-failure fail-closed behavior.
- A 2026-08-17 isolated run with pinned `@deepseek-ai/dsh@0.1.0-rc.6` and Node
  24.15.0 started the real Web/Host, returned a real plugin inventory with
  `dsh-plugin-debug` enabled/active, and successfully dispatched
  `plugin_check`, `plugin_hotswap_check` and `dsh_agent_report` through the
  real ToolRuntime. No real user Profile or credentials were accessed.
- The report tool saw an empty `SessionQuery` (0 Sessions/0 events), so this is
  registration and dispatch evidence, not data-bearing report proof.
  `plugin_hotswap_check` returned `UNAVAILABLE` and did not attempt a switch.
- In the same rc.6 environment, `session.create` failed with the external
  `agent-preset-invalid` / duplicate `deployment:persona` condition for
  `standard` and `minimal`. Real business Session history and model requests
  remain unverified; do not attribute that runtime limitation to this plugin.

No current numeric `packageFileCount` is asserted here. The count must be
regenerated from the final candidate with the real pack command before any
publication evidence is written.
