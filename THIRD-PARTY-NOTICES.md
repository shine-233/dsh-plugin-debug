# Third-party notices

The combined package is primarily self-authored DSH runtime and Host-side
PowerShell/Node tooling. It does not vendor `node_modules` or copy community
plugin source. The pinned runtime dependency inventory is recorded in
`DEPENDENCY-LICENSE-REPORT.md` for review against
`packages/dsh-plugin-debug/tools/runtime/package-lock.json`.

The plugin-store source and capability were removed and must not be
reintroduced as a dependency or publication component.
