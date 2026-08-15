# Combined package integration contract

`dsh-plugin-debug` is the only public package in this repository. It combines
pointer provenance, Host diagnostics, plugin health, incident correlation,
recovery, Crash Guard, Workbench and the Debug launcher. The plugin-store
capability is intentionally removed: this package does not install, call or
ship `dsh-plugin-store`.

The canonical offline integration test is:

```powershell
.\tools\Test-DSHPluginIntegration.ps1
```

`Test-DSHProvenanceIntegration.ps1` is retained under its historical name as
a compatibility entry for existing local automation. It is not a second
package and does not define a separate legacy product. New scripts
and documentation should use `Test-DSHPluginIntegration.ps1`.

## What this test proves

The test stages the current package into a temporary directory and uses a
local fake DSH CLI. It never contacts a registry, starts a real DSH Profile or
uses a real browser. The assertions cover:

- the public package identity is `dsh-plugin-debug`;
- the bundle manifest declares the independent combined package;
- canonical Debug pointer markers and legacy provenance aliases are present;
- the client artifact contains the pointer bridge, event and evidence API;
- the combined launcher has no plugin-store or old one-click coupling and
  keeps the optional Agent overlay explicit;
- the package installs into an isolated fake Profile as `dsh-plugin-debug`;
- the installed package contains the client artifact but no plugin-store
  content;
- the offline incident-correlation fixture passes without network access.

The test returns a JSON result with `result = PASS` or `result = FAIL`. Use
`-KeepTemp` when a failed staged package needs inspection:

```powershell
.\tools\Test-DSHPluginIntegration.ps1 -KeepTemp
```

## Local verification boundary

Run the package checks from `packages\dsh-plugin-debug`:

```powershell
npm run check
.\tools\Test-DSHPluginIntegration.ps1
```

The test is an offline package-contract check. A passing result does not prove
that a particular DSH release can load the bundle, that a live Host exposes
every diagnostic API, that a real browser renders the pointer overlay, or that
the full Web/Host E2E workflow succeeds. `Test-DSHPointerBrowser.ps1` is the
separate browser-level check; an unavailable Playwright/browser runtime must
be reported as `UNAVAILABLE`, not converted into a pass.

## Pointer contract

The canonical contract is recorded in `bundle-manifest.json` under
`features.pointerProvenance`:

- `window.__DSH_PLUGIN_DEBUG__` and the equivalent document property;
- `meta[data-dsh-debug-bridge="1"]` for frozen page realms;
- the `dsh-plugin-debug:pointer` event;
- observation schema `2`, with bounded `observationId`, `pageObservationId`,
  `observedAt`, plugin/module/Slot evidence and `confidence`;
- `getPointerEvidence()` for a metadata-only page observation.

The client also exposes `__DSH_PLUGIN_PROVENANCE__` and the old provenance
bridge selector as compatibility aliases. Those aliases do not identify
another package and are not the canonical publication contract.

## Host-side evidence boundary

`DSH-Provenance.ps1` is the unified dispatcher inside the same package. Its
incident, trace, repro, repair and diagnostics actions call local `tools`
modules. Incident and trace output is metadata-only: it omits raw Tool
arguments/results, credentials, cookies, authorization values, commands,
scripts and complete working directories. A local report is evidence capture,
not proof that DSH was repaired.

Pointer evidence is an observation, not causal attribution. For a page report,
pass `-PointerPath` to `DSH-Provenance.ps1 -Action incident-capture`; ambiguous
or incomplete evidence requires manual review.

The self-repair path is dry-run by default and requires explicit `-Force` to
write a reversible Guard patch. Plans reject dangerous fields at any nesting
level. Receipts bind pre-image and post-image hashes for the expected Guard
files; a changed post-image returns `ROLLBACK_CONFLICT` without overwriting a
user edit. `-RuntimeRoot` is bounded to a caller-provided runtime checkout and
the package's documented fallback roots; it does not search the whole disk.
