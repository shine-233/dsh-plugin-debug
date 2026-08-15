# Publishing Procedure

This is the final local-to-GitHub handoff for the single combined DSH Debug
Plugin. The public package directory is `packages/dsh-plugin-debug`, while its
runtime package ID remains `dsh-plugin-debug`. This file is not an upload
script and contains no remote URL.

The requested target is the public repository `shine-233/dsh-plugin-debug` and
the recorded copyright holder is `shine-233`. The publication fields, package
repository metadata and MIT notices are filled before the first commit. If the
target changes later, update those fields and review the staged diff before
creating a new remote or pushing.

## Local staging sequence

From the candidate root, after those decisions are confirmed:

```powershell
git init -b main
git status --short --branch
git add --dry-run -A
git diff --check
git add -A
git diff --cached --check
git diff --cached --stat
git commit -m "chore: prepare DSH Debug Plugin"
```

Review the staged list before configuring any remote. Never stage `.dsh`,
`.codex`, logs, state, credentials, coverage, runtime `node_modules` or the
excluded store. A local commit is not a GitHub publication.

## Post-push verification

Only after the user confirms the target remote and approves the staged list,
configure the remote and push. Then verify the default branch and clone into a
fresh temporary directory. Run the single package Node/PowerShell suites and
publication-boundary checks from that fresh clone.
