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

For the existing `shine-233/dsh-plugin-debug` maintenance path, do not rerun
`git init` or replace `origin`: first read `git status --short --branch`,
`git log`, `git remote get-url origin` and `git ls-remote origin`. The
candidate source commit, the remote `sourceCommit`, and the later release
evidence commit are separate gates.

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
excluded store. `git add -A` stages every current worktree change, including
unrelated user edits; inspect `git status --short` first and stop if the list
is not exactly the candidate you intend to publish. A local commit is not a
GitHub publication.

Before staging, run `git diff --check` and inspect `npm pack --dry-run --json
--ignore-scripts`. The package must not contain `.env` content, raw Tool
arguments/results, credentials, state, logs, coverage or `node_modules`.

## 中文上传步骤

从候选仓库根目录执行。下面的 `Verify-Publication.ps1`、Node 测试和
PowerShell 测试必须保留真实退出码；不要把当前工作区的历史输出复制成新的
证据。

```powershell
Push-Location C:\path\to\dsh-open-source
git status --short --branch
.\scripts\Verify-Publication.ps1

Push-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHPluginIntegration.ps1 -SkipCompatibility
Pop-Location

gh auth status --hostname github.com
git remote get-url origin
git diff --check
git diff --stat
```

如果使用辅助脚本，先确认 `gh auth status` 的账号、仓库名和可见性正确，再
在干净且已审阅的工作树中运行：

```powershell
Push-Location .\packages\dsh-plugin-debug
.\Publish-GitHub.ps1 -Visibility public -RepositoryName dsh-plugin-debug -SkipPush
Pop-Location
```

该脚本会运行 `npm run check`，随后执行 `git add -A`、提交，并在未提供
`-SkipPush` 时推送；它不会自动完成完整 PowerShell 套件、fresh clone 或
凭据人工审阅。因此工作树含有无关修改时不能直接运行它。确认 staged 列表、
`Verify-Publication.ps1` 和测试结果后，才执行：

```powershell
git push -u origin main
git ls-remote origin refs/heads/main
```

GitHub CLI 不可用时，先用 `gh auth login --hostname github.com --git-protocol
https --web` 完成认证；如果 `origin` 指向的账号、仓库或可见性不是预期值，
停止，不要覆盖远端。

## Post-push verification

Only after the user confirms the target remote and approves the staged list,
configure the remote and push. Then verify the default branch and clone into a
fresh temporary directory. Run the single package Node/PowerShell suites and
publication-boundary checks from that fresh clone.

推送后先把回读到的提交记为 `sourceCommit`，在 fresh clone 中验证这个提交。
验证通过后，再单独提交一次“release evidence”更新 `RELEASE-MANIFEST.json`：
`publishedCommit` 记录已经验证的 `sourceCommit`，而不是试图让一个提交记录
自身的 SHA；随后对这个 evidence commit 再运行一次发布验证。这样不会产生
自引用哈希，也能保留“代码提交”和“证据提交”的区别。

| Field | Meaning | Allowed before the gates pass |
| --- | --- | --- |
| `publication.pushPerformed` | The exact candidate commit was pushed to the configured remote | `false` |
| `publication.publishedCommit` | The 40-character source commit that was pushed and passed fresh-clone verification | `null` |
| `verification.publicationVerifierPassedAt` | UTC timestamp from a real `Verify-Publication.ps1` exit code 0 | `null` |
| `verification.freshCloneVerifiedAt` | UTC timestamp after the fresh clone passes the agreed suite | `null` |

Keep `status: candidate` until both timestamps exist, the recorded source commit
was read from the remote, and the fresh clone has passed. Only then may the
evidence commit change the status to `published`. Never fill a timestamp from an
earlier run, a static parser result, or an uncommitted worktree.
