# Public release checklist

This checklist is the gate for the single combined DSH Debug Plugin. Repeat it
for every version. The current v0.8.4 closeout is recorded first; the v0.8.3
section below is retained as historical evidence from source commit
`591ca0da959465a1207030cd7eb91372d8e90b2a`.

## v0.8.4 current publication — source and boundary

The v0.8.4 source implementation commit is
`687dbaba3897a50ff2c797049ad9755eb76576d5`; the evidence commit on
`origin/main` and the `v0.8.4` tag is
`41bb77a6f8cd872d98a39be14d99b2f338c890f5`. The GitHub Release is public,
non-draft and non-prerelease. This is a GitHub source release; the package is
not published to npm.

- [x] `packages/dsh-plugin-debug` is the only public package and is version `0.8.4`; `dsh-plugin-store` is absent and removed from the capability surface.
- [x] The local worktree and `origin/main` are clean and point to the published evidence commit; the annotated `v0.8.4` tag resolves to that commit.
- [x] The exact remote fresh clone of `origin/main` passed `Verify-Publication.ps1`: 108 package files, no forbidden directories, no sensitive artifacts and parseable JSON.
- [x] The exact fresh clone passed 95/95 Node tests, build/generated-artifact/syntax/workflow-pin checks, lint, format, honest typecheck (`SKIPPED` because the package has no TypeScript sources), runtime-lock checks, SBOM checks and both high-severity npm audits.
- [x] The exact fresh clone passed the 61-file/59-PowerShell-file/51-fixture Standalone suite and the canonical integration suite; the latter passed offline installation, client bridge, legacy alias, combined launcher, Agent overlay and Host incident correlation.
- [x] The package tarball was built through the real `prepack` lifecycle with 108 entries. Node-safe exports loaded from the tarball and the browser client registered through a minimal `window.__ModuleLoader__` contract; browser E2E remains `UNAVAILABLE` when no browser runtime is installed.
- [x] CI run `32025200100` and CodeQL run `32025200153` succeeded for the evidence commit. Main branch protection requires the Node, Windows, fresh-clone and CodeQL checks; Dependabot security updates and secret push protection are enabled.
- [x] A real isolated rc.6 Host produced a data-bearing `SessionQuery` report: 1 session listed/read, 15 events used, 1 failed turn, 0 tool calls, 0 tokens and `¥0.0000`. The request failed closed with `MISSING_CREDENTIAL`; this proves the report's real failure/data path, not a successful model or billing path.
- [x] In the current isolated Profile, `session.create` with the minimal preset passed. An older external instance showed `agent-preset-invalid`/duplicate `deployment:persona`; that limitation was not universal in the current isolated run and must not be stated as an unconditional Debug failure.
- [x] Real Host hotswap capability inspection failed closed to `MANUAL_REVIEW`/`NOT_ATTEMPTED` because the inventory was truncated and no authoritative lifecycle contract was exposed; no production hotswap was executed.
- [x] `dsh-plugin-check` was tested in isolation and is not installed or merged: it conflicts with Debug's same-named `plugin_check` when co-installed, and its `git`/`gh` behavior does not meet Debug's offline-only contract.

The following remain intentionally unproven and are not silently promoted to
release claims: a successful provider/model response with real credentials,
real token/cost accounting, a model-generated Tool Call, production-Profile
third-party installation, production hotswap, and cross-platform runtime
compatibility. These require explicit runtime authority and/or user-supplied
provider credentials.

## v0.8.3 publication — source and boundary

The checked items below describe the published v0.8.3 source snapshot. They are
not evidence for the historical 0.8.2 tag.

- [x] `packages/dsh-plugin-debug` is the only public package and contains the runtime plus Host-side debug/launcher tools.
- [x] The package retains runtime ID `dsh-plugin-debug` and the published version is `0.8.3`.
- [x] Crash Guard's fake runtime is generated only in a bounded temporary test directory; no independent fixture package is present.
- [x] Startup incident receipts and the read-only plugin bisect plan are covered by candidate regression tests and contain no raw payloads or automatic Profile mutation.
- [x] Startup health fail-closes unresolved or unavailable plugin failures: safe third-party mappings may be quarantined once, while core/unknown/ambiguous failures produce a `degraded` receipt without arbitrary disable or a second restart.
- [x] Diagnostics-report diffing is covered by a Windows PowerShell regression; sensitive or invalid inputs fail closed to `MANUAL_REVIEW`/`FAIL`.
- [x] Static plugin preflight is covered by a Windows PowerShell regression; it is offline/read-only, never executes plugin code, and routes dynamic access to `MANUAL_REVIEW`.
- [x] Offline plugin repository health checking is exposed as `plugin_check`; it inspects bounded manifests, patch shapes, build traps and hub metadata without installing or executing a candidate.
- [x] `plugin_hotswap_check` is a read-only lifecycle capability probe; it reports Host-contract and target risks but never calls `_dispose`, `refresh`, `update` or cache eviction.
- [x] `dsh_agent_report` is a bounded, deterministic Session/Token/Tool/risk report; its local cost is labelled an estimate, not a bill, and it never calls a model, executes a command, reads credentials or writes a Session.
- [x] Dependency graph inspection is covered by a Windows PowerShell regression; missing packages, cycles and unreferenced local packages fail closed without install or execution.
- [x] Offline trace-loop analysis is covered by a Windows PowerShell regression; repeated metadata windows are reported without runtime blocking, Session creation or Profile mutation.
- [x] Offline trace-recursion analysis is covered by a Windows PowerShell regression; bounded lifecycle depth is reported without returning agent IDs, Session IDs or payloads.
- [x] The observer-only task guardian is covered by Node regressions for loop/recursion detection, redaction, bounded event state and non-termination behavior.
- [x] The guardian status checker has offline idle/busy fixtures and uses exit code 2 for busy, without performing restart or termination actions.
- [x] The client breadcrumb ring buffer is bounded at 80 entries, reports dropped entries, and is covered by a redaction regression test.
- [x] The diagnostics-diff action compares only bounded metadata and routes sensitive inputs to `MANUAL_REVIEW`.
- [x] The plugin-store source and capability are absent from the candidate and have been removed locally.
- [x] The publication staging tree and npm tarball exclude `.dsh`, `.codex`, Profile state, logs, state, temporary files, `node_modules` and coverage output.
- [x] Deterministic SPDX 2.3 and CycloneDX 1.5 SBOMs are committed under `packages/dsh-plugin-debug/sbom/`; `npm run sbom:check` rejects stale or non-deterministic output.
- [x] `check:runtime-lock` compares the runtime manifest and lockfile, and `check:runtime-lock:installed` compares every installed package version after `npm ci`.
- [x] The package has explicit lint, format, coverage and honest typecheck gates; the current JavaScript/PowerShell-only typecheck reports `SKIPPED` instead of claiming TypeScript coverage.
- [x] Real DSH Host/Web compatibility is a separate manual opt-in lane requiring `-ConfirmRealDsh`; it never uses the fixture server, calls a model, installs a plugin or mutates an existing Profile.
- [ ] The current working tree has no generated dependency directories. Local dependency-backed checks intentionally leave `packages/dsh-plugin-debug/node_modules` and/or `packages/dsh-plugin-debug/tools/runtime/node_modules` outside the publication staging tree until cleanup.
- [x] Recovery regression proves sensitive files such as `.env` are recorded as excluded and are never copied or restored.
- [x] Candidate package trace fixtures contain metadata only: no raw Tool arguments, result bodies or credentials; dangerous-operation detection uses bounded synthetic/event text for classification only and never executes it.
- [x] Guard API rejects non-loopback BaseUrl values unless an explicit host allowlist is configured.

## Metadata and licensing

- [x] Root and package MIT copyright holder is recorded as `shine-233`.
- [x] The public package manifest has a real `repository`, `bugs` and `homepage` field.
- [x] `RELEASE-MANIFEST.json` records evidence-backed UTC `publicationVerifierPassedAt`/`freshCloneVerifiedAt` timestamps for source commit `591ca0da959465a1207030cd7eb91372d8e90b2a`.
- [x] Dependency license fields were inventoried against the exact pinned runtime lockfile; this is not legal advice.

## Repository automation (configured in the source tree)

- [x] `.github/workflows/ci.yml` contains the Node 22/24 matrix, Windows PowerShell checks, publication-boundary checks, pinned-runtime advisory audit, fresh-clone gate, tarball smoke and consumer-export checks.
- [x] `.github/workflows/compatibility.yml` provides a manual, explicitly confirmed real DSH Host/Web inventory lane and uploads its evidence without making it a required check.
- [x] `.github/workflows/codeql.yml` contains JavaScript/TypeScript and GitHub Actions analysis lanes.
- [x] `.github/dependabot.yml` contains monthly update lanes for the package, pinned runtime and GitHub Actions.
- [ ] Remote branch protection, Dependabot alerts, automatic security fixes and other GitHub repository settings have been confirmed from the remote. Local workflow files do not prove those settings are active.

## Verification

```powershell
# Start from the candidate repository root. Verify before npm ci because the
# verifier intentionally rejects generated node_modules/state/log directories.
Set-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1

Push-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
npm audit --prefix .\tools\runtime --registry=https://registry.npmjs.org --omit=dev --audit-level=high
npm test
npm run check
npm run lint
npm run format:check
npm run typecheck
npm run coverage
npm run check:runtime-lock
npm run sbom:check
npm run check:runtime-lock:installed
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
npm pack  # run the real prepack lifecycle, then extract and smoke-test the tarball
Pop-Location
```

After dependency-backed checks, remove only the generated dependency folders
from this candidate checkout, or use a clean/fresh clone for the final boundary
check. Then run `scripts\Verify-Publication.ps1` again from that clean tree.
Classify any intentional fixture markers; never treat a green static check as
proof of a real production DSH or successful GitHub publication.

## GitHub gate

- [x] Target GitHub owner, repository name and visibility are recorded (`shine-233/dsh-plugin-debug`, public).
- [x] A reviewed source commit for the `0.8.3` candidate was created: `591ca0da959465a1207030cd7eb91372d8e90b2a`.
- [x] Remote URL is explicitly recorded before any push.
- [x] Push was performed only after the staged contents were approved; the source commit is present on `origin/main`.
- [x] An exact-remote fresh clone passed the single-package tests, publication checks, audit, SBOM, runtime lock, PowerShell and tarball smoke gates for `0.8.3`.

## Published 0.8.3 evidence

- Published version: `0.8.3`.
- Published status: `RELEASE-MANIFEST.json` has `status: published`,
  `pushPerformed: true`, `publishedCommit` and `verification.sourceCommit`
  set to `591ca0da959465a1207030cd7eb91372d8e90b2a`, with both UTC timestamps.
- The publication verifier and both dry-run and real prepack `npm pack` reports
  contain 102 files. The exact extracted tarball passed package-only Standalone,
  offline consumer installation and all declared export imports.
- The exact fresh clone passed plugin/runtime `npm audit` with 0 vulnerabilities,
  Node 22/24 tests, 91.48% line coverage, lint, format, honest typecheck,
  runtime lock metadata/installed-tree checks, 584-component SPDX/CycloneDX
  SBOM checks, PowerShell parsing, Recovery, Known-good and integration.
- On 2026-08-17, an isolated temporary profile with pinned
  `@deepseek-ai/dsh@0.1.0-rc.6` and Node 24.15.0 started the real DSH Web/Host
  successfully: HTTP readiness was 200, the host was identified as DSH, the
  supervisor was healthy, and the real plugin inventory reported
  `dsh-plugin-debug` as enabled/active with no failed entries. This used
  temporary roots and did not access the real user Profile or credentials.
- In that same isolated run, real ToolRuntime registration and dispatch
  succeeded for `plugin_check`, `plugin_hotswap_check` and `dsh_agent_report`;
  each tool schema was registered and each dispatch returned `isError=false`.
  `plugin_hotswap_check` correctly returned `UNAVAILABLE` with execution not
  attempted. `dsh_agent_report` returned a valid `PASS` report from
  `SessionQuery`, but there were zero Sessions and zero events, so this proves
  registration/dispatch only, not a populated historical report.
- Direct `session.create` in the same pinned rc.6 isolated profile remains
  blocked by an external `agent-preset-invalid` error: both `standard` and
  `minimal` hit duplicate `deployment:persona` registration. This is an
  upstream/runtime limitation, not evidence that the report tool executed
  incorrectly. Real business Session history, model requests, third-party
  installation and cross-platform compatibility remain unverified.

The evidence levels are intentionally separate: source and offline fixtures
prove implementation contracts; fake/loopback suites prove bounded local
flows; the isolated pinned rc.6 run proves real Web/Host loading and tool
dispatch; only a successful data-bearing Session and model request would prove
the end-to-end report experience.

## Historical 0.8.2 CI evidence (not current v0.8.3 evidence)

- The historical source commit was `b234e79dfe7b349568f7f3e3c63504979f0e74e0`.
- GitHub Actions run `31936340306`: `node-tests`, `windows-debug-suite` and
  `Fresh clone publication gate` all completed successfully.
- CodeQL run `31936340261`: JavaScript/TypeScript and Actions analysis both
  completed successfully.
- Fresh-clone standalone suite: `result=PASS`, `filesChecked=59`,
  `powershellFilesParsed=55`, `fixtureChecks=51`.
- Root and fresh-clone `Verify-Publication.ps1`: `result=PASS`,
  `packageFileCount=96`, `store=removed`, `forbiddenDirectories=absent`,
  `sensitiveArtifacts=absent`, `json=parseable`.
- Those results describe the historical `0.8.2` workflow and do not certify
  the current `0.8.3` worktree. The existing `v0.8.2` tag/release snapshot and
  the later `main` evidence documents must be reconciled before treating that
  release as a single consistent publication.
