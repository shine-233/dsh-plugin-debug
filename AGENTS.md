# DSH Debug Plugin candidate

- `packages/dsh-plugin-debug` is the only public component; its runtime ID is `dsh-plugin-debug`; older provenance Profiles require explicit migration.
- Its `tools` directory contains the combined Host-side diagnostics, recovery, Crash Guard, Workbench and foolproof launcher source.
- Crash Guard tests generate their intentionally failing runtime in a bounded temporary directory; do not add a standalone crash-fixture package.
- The plugin-store source and capability have been removed; do not restore them to the candidate.
- Never add `.dsh`, `.codex`, Profile state, logs, state, coverage, node_modules, credentials or local caches.
- Run Node tests, PowerShell parser checks and the standalone debug suite before changing publication status.
- `DSH_RUNTIME_ROOT` may override the pinned runtime root; the default is `packages/dsh-plugin-debug/tools/runtime`.
- Keep `RELEASE-MANIFEST.json`, `PUBLICATION-CHECKLIST.md` and the verifier aligned with the single-package tree.
- Do not claim real DSH Web, GitHub or production verification from static checks alone.
