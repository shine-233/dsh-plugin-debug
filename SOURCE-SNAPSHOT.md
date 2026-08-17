# Source snapshot status

This is the current single-package publication release source tree. The public remote is
`https://github.com/shine-233/dsh-plugin-debug.git`, default branch `main`.

| Component | Files | Notes |
| --- | ---: | --- |
| packages/dsh-plugin-debug | 102 files in the `v0.8.3` pack result | One combined runtime plugin plus Host-side diagnostics, recovery, Crash Guard, startup incident receipts, read-only plugin bisect planning, diagnostics-report diffing, static plugin preflight, offline plugin repository health checks, read-only hotswap capability probing, deterministic metadata-only agent/session reports, dependency graph inspection, offline trace-loop and bounded trace-recursion analysis, observer-only task guardian and its status checker, bounded client breadcrumbs, Workbench and one-click launcher; the small, synthetic `tools/fixtures` inputs ship for reproducible trace/pointer/bisect/dependency/trace-loop/recursion tests, while fake runtimes and temporary Profiles are generated at test time |

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
Version `0.8.3` uses source commit
`591ca0da959465a1207030cd7eb91372d8e90b2a`; that exact remote commit passed the
fresh-clone publication gate before the evidence commit was written. The
manifest records `published`, `pushPerformed=true`, the source commit, both UTC
verification timestamps, the 102-file pack result and the deterministic 584
component SPDX/CycloneDX SBOMs. The evidence commit and the `v0.8.3` tag carry
this publication record; the npm registry is intentionally not used.

The historical `v0.8.2` release was not a clean evidence baseline: at that
time, the `main` evidence record named source commit
`b234e79dfe7b349568f7f3e3c63504979f0e74e0` while the `v0.8.2` tag/source
archive still contained candidate/null publication fields and its release body
had malformed literal newlines/control characters. Treat `0.8.2` as an
inconsistent historical snapshot, not as proof for v0.8.3. The older local
publication baseline was `0.8.1` at
`f74e06d8ce82d5c9d7b091e9ab000248e166f368`; future functional changes must
create a new candidate source commit and repeat the same fresh-clone and
publication gates.

## Published 0.8.3 evidence layers

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

The exact source commit produced 102 npm pack entries in both the dry-run
publication check and the real prepack/pack extraction smoke. The unpacked
tarball contained the seven expected `lib/` modules, both SBOM files and no
forbidden directories; package-only Standalone and an offline consumer import
also passed.
