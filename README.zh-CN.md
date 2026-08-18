# dsh-plugin-debug

这是 `dsh-plugin-debug` 的仓库级中文入口。它把 DSH 的检测、调试、来源追踪、事故取证、恢复、Trace 分析、插件预检、任务 Guardian、Crash Guard 和一键启动工具合并成一个公开包；`dsh-plugin-store` 不在这个包中，也不会被启动器安装或调用。

完整的中文操作手册在 [packages/dsh-plugin-debug/README.zh-CN.md](packages/dsh-plugin-debug/README.zh-CN.md)，维护顺序见 [ROADMAP.md](ROADMAP.md)，GitHub 首页简要说明在 [README.md](README.md)。

`0.8.4` 已完成 GitHub source release 的源码、CI、CodeQL 和 fresh-clone 证据闭环：精确源码提交为
`687dbaba3897a50ff2c797049ad9755eb76576d5`，evidence commit 为
`41bb77a6f8cd872d98a39be14d99b2f338c890f5`，发布包检查结果为 108 个文件。这个仓库不发布到 npm registry；真实有数据但失败的 SessionQuery 报告路径已验证（1 个 Session、15 条事件），但成功模型、真实 Token/费用、模型 Tool Call、生产第三方安装和跨平台兼容仍未证明。正式状态仍以 GitHub 远端 ref 和 [`RELEASE-MANIFEST.json`](RELEASE-MANIFEST.json) 为准。

如果你要找的是“系统学习 DSH”的仓库，请看公开的 [`shine-233/deepseek-harness-study`](https://github.com/shine-233/deepseek-harness-study)：它有 `START-HERE.md`、中文 README、00–27 分层学习入口、15 分钟任务单和固定版本索引。本仓库是可运行的调试插件和研究记录，不是教程；有数据 Session、模型请求、完整 Web/CLI E2E 和跨平台运行仍需另行验证。

## 快速开始

环境要求：Windows，建议 PowerShell 7（`pwsh`）和 Node.js 22 或更高版本；PowerShell 5.1 只作为兼容性检查宿主。进入包目录后可以运行：

```powershell
Set-Location .\packages\dsh-plugin-debug
npm test
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
```

这条启动命令要求本机已有 pinned runtime；想准备 runtime 时，再明确同意联网后执行 `npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund`。依赖锁文件目前保留了插件包使用国内镜像、固定 runtime 使用官方 npm registry 的事实；这是安装源选择，不是兼容性或安全认证。CI 的高危依赖审计会显式访问官方 advisory API，发布前若要统一 registry，必须重新生成 lockfile、重跑完整门禁并更新供应链记录。

只想安装本地包时，也可以使用 DSH CLI：

```powershell
dsh plugin --profile debug add . --offline
```

首次启动如果本地还没有固定版本的 DSH runtime，启动器可能先下载 pinned runtime；`--offline` 只约束本地 Debug bundle 安装。更新已经安装到 Profile 的本地源码时，先停止同一个 Profile/端口，再显式强制覆盖 bundle：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoInstall -NoBrowser
```

启动器第一次下载 runtime 时会严格使用包内 `tools/runtime/package-lock.json` 执行 `npm ci`；lockfile 缺失或与清单不一致会直接失败，不会静默改写依赖。网络不可用时请先在可联网环境完成安装，再用 `-NoInstall` 或已有 runtime 启动。

## 安全边界

Guardian 本身是 observer-only：它观察 Tool Call、Agent/Workflow 递归和中断事件，不终止任务、不杀进程、不重启 Host、不禁用插件、不修改 Profile。

整个包并不是无副作用的 observer-only 工具。`Crash Guard` 和 `Runtime Supervisor` 是单独的受控处置边界：它们可能停止已确认的 DSH 子进程、写入可逆 `guard-state.json`/`guard.patch.yml`，并最多执行一次重启；第二次失败进入 `degraded`，不会无限重启。底层 `tools/Start-DSH.ps1` 默认不启用 Crash Guard，公开的 Debug 启动包装器才会显式启用它。

启动自检只会自动隔离“能够由当前 Profile 唯一映射、且明确属于安全第三方插件”的失败条目。核心包、未知插件、歧义映射或 inventory 不可用时不会猜测并禁用任意包；这些情况会 fail closed，写入 `degraded` 的启动回执并停止继续启动。

默认诊断只保留脱敏元数据，不发布 Tool 参数、结果正文、`.env` 内容、凭据、Cookie、Authorization 或完整工作目录。Recovery 快照会记录敏感文件“存在但排除”，绝不会复制或恢复 `.env` 内容。

`dsh_agent_report` 可在 Host 提供 SessionQuery 或当前内存会话时生成脱敏的 Token、工具调用、失败、风险和内置估算费用报告；没有 Session 服务时会返回 `UNAVAILABLE`，不会调用模型、执行命令、读取凭据或写回历史。

`plugin_check` 是离线的插件仓库健康检查：看清单协议、patch 形态、构建陷阱和 hub 收录线索，不安装、不执行候选。`plugin_hotswap_check` 只检查 Host 是否公开了可审计的生命周期合同；没有权威、稳定、带版本的合同就返回 `UNAVAILABLE`，不会真的热切换。`dsh_agent_report` 借鉴 `dsh-whale-report` 的确定性报告形状，但只保留有界、脱敏、本地可审计的报告引擎，不读取余额、在线价格、凭据，不复制完整 Web UI，也不依赖上游运行时或上游构建清理命令。

报告里的危险命令（例如 `rm -rf`）只是对 Session 事件文本做风险分类，绝不会交给 shell 执行；测试中的这类字符串也是合成输入，不是插件要执行的动作。

## 当前真实验证的边界

截至 2026-08-18，使用隔离临时根目录、`@deepseek-ai/dsh@0.1.0-rc.6` 和 Node 24.15.0 做过真实 Host/Web 验证：页面 readiness 为 200，Host 被识别为 DSH，inventory 正常，并且此前的隔离探针已证明上述三个工具完成真实 ToolRuntime 注册和 dispatch。本轮工作树又用实际 shipped `web` Profile 跑通了 `Test-DSHCompatibility.ps1 -ConfirmRealDsh -StartPinnedRuntime`：HTTP 200、`host.describe`、`pluginInventory/list` 成功，134 条 inventory 中确认 `dsh-plugin-debug` active。随后真实 `SessionQuery` 读取 1 个 Session、15 条事件并生成了失败报告；`session.create(minimal)` 在当前隔离 Profile 通过。另对本机现有 `web` Profile 做了 `-NoInstall -NoPluginInstall` 启动复核，manifest/patch 哈希未变且测试进程已清理。这个验证没有访问或输出凭据，也没有发送模型请求。

报告识别出 1 个失败回合、0 Tool Call、0 Token、`¥0.0000`，失败原因是 `MISSING_CREDENTIAL`；这证明了真实有数据的失败报告路径，不证明成功模型、真实账单或模型 Tool Call。此前另一个外部实例曾出现 `agent-preset-invalid`/`deployment:persona` 重复注册，但当前隔离 Profile 没有复现，因此不能把它写成所有 Profile 必然失败。真实生产第三方安装、生产 hotswap 和跨平台兼容仍待验证。

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

`Verify-Publication.ps1` 会实际调用 `npm pack --dry-run`，因此只有取得真实 `result=PASS` 后才能更新发布清单。`npm run check` 还会验证 `src`/`lib` 生成物和 bundle manifest 的逐项 SHA-256；CI 会拒绝构建后仍有 dirty generated files 的提交。静态目录检查、Node 测试通过或本地 commit 都不等于 GitHub 已发布；fresh clone 和远端提交哈希必须单独记录。

根目录已经配置 `.github/workflows/ci.yml`、`.github/workflows/codeql.yml` 和 `.github/dependabot.yml`：分别负责 CI/发布门禁、JavaScript/TypeScript 与 Actions 扫描、以及插件/runtime/Actions 的依赖更新建议。远端分支保护、Dependabot 安全告警和自动修复属于 GitHub 设置，仍应以 GitHub 设置页/API 的当前状态为准，不能只从 workflow 文件推断。

## 如何更新功能

1. 修改 `src/`、`tools/`、入口脚本和测试源码，不手工编辑构建产物 `lib/` 或 `bundle-manifest.json`。
2. 为新功能增加脱敏正常路径和失败路径回归，并明确它不会访问、写入或终止什么。
3. 运行包测试、Standalone、集成测试和根目录发布验证器，保留每个命令的真实退出码。
4. 按 SemVer 更新 `package.json`，同步 `package-lock.json`，让构建脚本重新生成 `lib/` 和 bundle manifest。
5. 检查 `npm pack --dry-run --json --ignore-scripts` 的实际文件清单，确认没有商店、状态目录、日志、凭据或 raw trace payload。
6. 先把 candidate source commit 推送并从远端回读 `sourceCommit`；再从该远端提交创建 fresh clone 重跑测试。只有 fresh clone 通过后，才用单独的 evidence commit 更新 `RELEASE-MANIFEST.json` 的 `publishedCommit`、UTC 时间戳和 `status`，然后再推送 evidence commit。

上传 GitHub 前请先阅读 [PUBLISHING.md](PUBLISHING.md) 和 [PUBLICATION-CHECKLIST.md](PUBLICATION-CHECKLIST.md)。现成的上传辅助脚本是 [`packages/dsh-plugin-debug/Publish-GitHub.ps1`](packages/dsh-plugin-debug/Publish-GitHub.ps1)，必须从真实仓库 clone 中运行；它会定位到仓库根目录，不会在 `packages/dsh-plugin-debug` 内自动 `git init`。脚本会执行构建、暂存、提交和可选推送；它使用 `git add -A`，运行前必须先检查并清理工作树中的无关修改，不能把它当成隐私审查的替代品。

发布状态、源码快照、迁移边界和外部研究分别见 [RELEASE-MANIFEST.json](RELEASE-MANIFEST.json)、[SOURCE-SNAPSHOT.md](SOURCE-SNAPSHOT.md)、[MIGRATION-MANIFEST.md](MIGRATION-MANIFEST.md) 和 [RESEARCH-ECOSYSTEM.md](RESEARCH-ECOSYSTEM.md)。许可证为 MIT。
