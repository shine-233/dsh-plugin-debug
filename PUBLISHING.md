# Publishing Procedure

This is the final local-to-GitHub handoff for the single combined DSH Debug
Plugin. The public package directory is `packages/dsh-plugin-debug`, while its
runtime package ID remains `dsh-plugin-debug`. This file is not an upload
script and contains no remote URL.

## 状态判定（中文）

`candidate` 表示源码、文档和发布清单正在准备，不能称为已经发布。
只有在 `Verify-Publication.ps1` 实际返回 `result = PASS`、包测试和 fresh clone
验证均取得退出码 0，并且重新读取远端默认分支提交后，才可以把清单更新为
`published`。本地 commit、`npm pack --dry-run`、GitHub 页面可见或历史测试输出
都不能单独证明发布完成。

Guardian 只是 observer-only；Crash Guard/Runtime Supervisor 具有受控的进程停止、
可逆 Profile patch 和最多一次重启边界。发布说明必须把这两类能力分开描述。
`dsh-plugin-store` 是本候选的明确排除项，不应加入安装、测试或恢复流程。

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

Before staging, run `git diff --check` and inspect `npm pack --dry-run --json
--ignore-scripts`. The package must not contain `.env` content, raw Tool
arguments/results, credentials, state, logs, coverage or `node_modules`.

## Post-push verification

Only after the user confirms the target remote and approves the staged list,
configure the remote and push. Then verify the default branch and clone into a
fresh temporary directory. Run the single package Node/PowerShell suites and
publication-boundary checks from that fresh clone.

After the remote hash is read back, update `RELEASE-MANIFEST.json` only from the
same candidate commit:

| Field | Meaning | Allowed before the gates pass |
| --- | --- | --- |
| `publication.pushPerformed` | The exact candidate commit was pushed to the configured remote | `false` |
| `publication.publishedCommit` | The 40-character commit hash read back from `origin/main` | `null` |
| `verification.publicationVerifierPassedAt` | UTC timestamp from a real `Verify-Publication.ps1` exit code 0 | `null` |
| `verification.freshCloneVerifiedAt` | UTC timestamp after the fresh clone passes the agreed suite | `null` |

Keep `status: candidate` until both timestamps exist, the remote hash matches
`publishedCommit`, and the fresh clone has passed. Only then may the status be
changed to `published`. Never fill a timestamp from an earlier run, a static
parser result, or an uncommitted worktree.
