# Dependency license report

This candidate contains one public package: `packages/dsh-plugin-debug`, whose
runtime package ID is `dsh-plugin-debug`. Its bundled Host runtime lockfile
is `packages/dsh-plugin-debug/tools/runtime/package-lock.json` (lockfileVersion
3). `node_modules` is intentionally excluded from publication.

The lockfile currently records 587 runtime package entries, each with a license
field. The observed license labels are metadata for review, not legal advice:

- MIT: 465
- Apache-2.0: 76
- BSD-3-Clause: 17
- LGPL-3.0-or-later: 10
- ISC: 11
- BSD-2-Clause: 2
- remaining entries: combined licenses, Python-2.0 and 0BSD variants

The public runtime plugin uses optional peer dependencies supplied by DSH and
does not vendor a dependency tree. The project copyright holder is recorded as
`shine-233`. This inventory is not legal advice; review the exact lockfile and
all package licenses before changing the dependency graph or publishing a new
version.
