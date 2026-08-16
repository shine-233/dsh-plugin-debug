# dsh-plugin-debug

这是 `dsh-plugin-debug` 的仓库级中文入口。它把 DSH 的检测、调试、来源追踪、事故取证、恢复、Trace 分析、插件预检、任务 Guardian、Crash Guard 和一键启动工具合并成一个公开包；`dsh-plugin-store` 不在这个包中，也不会被启动器安装或调用。

完整的中文操作手册在 [packages/dsh-plugin-debug/README.zh-CN.md](packages/dsh-plugin-debug/README.zh-CN.md)，GitHub 首页简要说明在 [README.md](README.md)。

## 快速开始

环境要求：Windows PowerShell、Node.js 22 或更高版本。进入包目录后可以运行：

```powershell
Set-Location .\\packages\\dsh-plugin-debug
npm ci --ignore-scripts
npm test
.\\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoBrowser
```

只想安装本地包时，也可以使用 DSH CLI：

```powershell
dsh plugin --profile debug add . --offline
```

首次启动如果本地还没有固定版本的 DSH runtime，启动器可能先下载 pinned runtime；`--offline` 只约束本地 Debug bundle 安装。更新已经安装到 Profile 的本地源码时，先停止同一个 Profile/端口，再显式强制覆盖 bundle：

```powershell
.\\tools\\Stop-DSH.ps1 -Profile debug -Port 3081
.\\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoBrowser
```

## 安全边界

Guardian 本身是 observer-only：它观察 Tool Call、Agent/Workflow 递归和中断事件，不终止任务、不杀进程、不重启 Host、不禁用插件、不修改 Profile。

整个包并不是无副作用的 observer-only 工具。`Crash Guard` 和 `Runtime Supervisor` 是单独的受控处置边界：它们可能停止已确认的 DSH 子进程、写入可逆 `guard-state.json`/`guard.patch.yml`，并最多执行一次重启；第二次失败进入 `degraded`，不会无限重启。底层 `tools/Start-DSH.ps1` 默认不启用 Crash Guard，公开的 Debug 启动包装器才会显式启用它。

启动自检只会自动隔离“能够由当前 Profile 唯一映射、且明确属于安全第三方插件”的失败条目。核心包、未知插件、歧义映射或 inventory 不可用时不会猜测并禁用任意包；这些情况会 fail closed，写入 `degraded` 的启动回执并停止继续启动。

默认诊断只保留脱敏元数据，不发布 Tool 参数、结果正文、`.env` 内容、凭据、Cookie、Authorization 或完整工作目录。Recovery 快照会记录敏感文件“存在但排除”，绝不会复制或恢复 `.env` 内容。

Host API 默认只允许 loopback 地址。若确实需要访问受信任的远端 Host，必须显式设置 `DSH_DEBUG_API_ALLOWED_HOSTS`，例如：

```powershell
$env:DSH_DEBUG_API_ALLOWED_HOSTS = 'debug-host.example'
```

## 测试与发布

源码仓库包含 Node 测试、PowerShell 回归脚本和合成脱敏 fixture，别人可以审阅和复现测试过程：

```powershell
Push-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1

Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHPluginIntegration.ps1 -SkipCompatibility
Pop-Location
```

`Verify-Publication.ps1` 会实际调用 `npm pack --dry-run`，因此只有取得真实 `result=PASS` 后才能更新发布清单。静态目录检查、Node 测试通过或本地 commit 都不等于 GitHub 已发布；fresh clone 和远端提交哈希必须单独记录。

## 如何更新功能

1. 修改 `src/`、`tools/`、入口脚本和测试源码，不手工编辑构建产物 `lib/` 或 `bundle-manifest.json`。
2. 为新功能增加脱敏正常路径和失败路径回归，并明确它不会访问、写入或终止什么。
3. 运行包测试、Standalone、集成测试和根目录发布验证器，保留每个命令的真实退出码。
4. 按 SemVer 更新 `package.json`，同步 `package-lock.json`，让构建脚本重新生成 `lib/` 和 bundle manifest。
5. 检查 `npm pack --dry-run --json --ignore-scripts` 的实际文件清单，确认没有商店、状态目录、日志、凭据或 raw trace payload。
6. 先把 candidate source commit 推送并从远端回读 `sourceCommit`；再从该远端提交创建 fresh clone 重跑测试。只有 fresh clone 通过后，才用单独的 evidence commit 更新 `RELEASE-MANIFEST.json` 的 `publishedCommit`、UTC 时间戳和 `status`，然后再推送 evidence commit。

上传 GitHub 前请先阅读 [PUBLISHING.md](PUBLISHING.md) 和 [PUBLICATION-CHECKLIST.md](PUBLICATION-CHECKLIST.md)。现成的上传辅助脚本是 [`packages/dsh-plugin-debug/Publish-GitHub.ps1`](packages/dsh-plugin-debug/Publish-GitHub.ps1)，它会执行构建、暂存、提交和可选推送；脚本使用 `git add -A`，运行前必须先检查并清理工作树中的无关修改，不能把它当成隐私审查的替代品。

发布状态、源码快照、迁移边界和外部研究分别见 [RELEASE-MANIFEST.json](RELEASE-MANIFEST.json)、[SOURCE-SNAPSHOT.md](SOURCE-SNAPSHOT.md)、[MIGRATION-MANIFEST.md](MIGRATION-MANIFEST.md) 和 [RESEARCH-ECOSYSTEM.md](RESEARCH-ECOSYSTEM.md)。许可证为 MIT。
