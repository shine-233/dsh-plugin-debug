# Embedded provenance compatibility in the Debug plugin

`dsh-plugin-debug` is the single public package. Pointer provenance is built
into its Web Client bundle and its Host-side diagnostics, incident, recovery,
Crash Guard and Workbench scripts live in the same package. There is no second
`dsh-plugin-debug` package; this flow has no plugin-store capability.

Use `Start-DSH-Debug.vbs` for the normal Debug entry. The internal
`DSH-Provenance.ps1` dispatcher remains as a compatibility path for existing
actions, but the retired provenance-named startup wrappers are no longer part
of the public package. `Start-DSH-Combined.vbs` additionally enables the
optional Kimi/Codex Agent overlay from `tools\combined-agents.patch.yml`.
The overlay is opt-in and is not a runtime dependency of the Debug package.

The launcher installs the package directly into the selected Profile using an
offline `plugin add` operation. It uses the pinned runtime manifest at
`tools\runtime\package.json` when a DSH runtime is not already available. The
launcher Supervisor owns only the child process started by that invocation and
allows at most one reversible third-party quarantine-and-restart cycle.

## Build and integration check

`scripts\build.mjs` builds `src` into `lib` and regenerates
`bundle-manifest.json`; no sibling provenance checkout or copy script is
required. Run the package-local checks from this directory:

```powershell
npm run check
.\tools\Test-DSHProvenanceIntegration.ps1
```

The integration check stages the current package into a temporary directory and
uses an offline fake DSH CLI. It proves the package identity, canonical and
legacy bridge markers, combined launcher and Agent overlay wiring, Profile
installation as `dsh-plugin-debug`, and the offline incident-correlation
fixture. It does not claim real DSH Web readiness or browser E2E coverage.

## Pointer contract

The canonical contract is recorded in `bundle-manifest.json` under
`features.pointerProvenance`:

- `window.__DSH_PLUGIN_DEBUG__` and the equivalent document property
- `meta[data-dsh-debug-bridge="1"]` for frozen page realms
- `dsh-plugin-debug:pointer`
- observation schema `2`, with bounded `observationId`, `pageObservationId`,
  `observedAt`, plugin/module/Slot evidence and `confidence`
- `getPointerEvidence()` for a metadata-only page observation

The client also exposes `__DSH_PLUGIN_PROVENANCE__` and the old provenance
bridge selector as compatibility aliases. They do not identify another package
and are not the canonical publication contract.

## Host-side evidence boundary

`DSH-Provenance.ps1` is the unified dispatcher inside this same package. Its
`incident-capture`, `trace-autopsy`, `repro-export`, `repair-plan`, and
`repair-apply` actions call the local `tools` modules directly. Incident and
trace output remains metadata-only: it omits raw Tool arguments/results,
credentials, cookies, authorization values, commands, scripts, and complete
working directories. Writing a local report is not proof that DSH was repaired.

For a pointer report produced by the Web page, pass `-PointerPath` to
`DSH-Provenance.ps1 -Action incident-capture`. Pointer evidence is an
observation, not causal attribution; ambiguous or incomplete evidence requires
manual review.

The self-repair path is dry-run by default and requires explicit `-Force` to
write a reversible Guard patch. Plans reject dangerous fields at any nesting
level. Receipts bind pre-image and post-image hashes for exactly the expected
Guard files; a missing or changed post-image returns `ROLLBACK_CONFLICT`
without overwriting the user's edit.

The optional `-RuntimeRoot` argument lets diagnostics use a caller-provided
runtime checkout. It checks only that root and the package's bounded fallback
roots; it does not search the whole disk.
