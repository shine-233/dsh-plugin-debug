# Source snapshot status

This is one local, uncommitted, unpublished package candidate. It has no
configured remote and has not been pushed to GitHub.

| Component | Files | Notes |
| --- | ---: | --- |
| packages/dsh-plugin-debug | 79 npm-pack entries | One combined runtime plugin plus Host-side diagnostics, recovery, Crash Guard, Workbench and one-click launcher; test programs stay in the GitHub source tree, while temporary fixtures are generated at test time |

The original provenance, debug-suite and one-click inputs were removed from the
projects tree after migration review and are not package dependencies. The
store directory was already absent and remains disabled. Repeat source/hash
comparison after any functional change; do not silently call this snapshot
current without that comparison.
