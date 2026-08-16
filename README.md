# dsh-plugin-debug（DSH 调试插件）

这是仓库首页的中文说明。它把我创作的 DSH 检测、调试、恢复、插件健康检查、崩溃隔离、事故取证、Trace 分析、任务守护和一键启动能力合并为一个可审阅、可测试的开源插件。公开运行时包只有 `dsh-plugin-debug`，源码目录是 `packages/dsh-plugin-debug`。

GitHub 仓库：[shine-233/dsh-plugin-debug](https://github.com/shine-233/dsh-plugin-debug)。包内的 [`README.zh-CN.md`](packages/dsh-plugin-debug/README.zh-CN.md) 是更完整的中文操作手册；包内默认显示的 [`README.md`](packages/dsh-plugin-debug/README.md) 同样是中文，不要求读者先看英文文档。

当前发布状态以 [`RELEASE-MANIFEST.json`](RELEASE-MANIFEST.json) 为准：候选版本必须经过本地测试、发布边界检查和 fresh clone（全新克隆）复验后才能称为正式发布。仓库页面显示的提交或 npm 包版本不能替代这些门禁。

插件商店 `dsh-plugin-store` 没有进入这个包，也不再是运行时依赖。旧的 provenance、debug-suite 和 one-click 源码已经完成迁移并从项目目录移除；当前公开源代码的唯一事实来源是这个单包。具体名称和迁移记录见 [`MIGRATION-MANIFEST.md`](MIGRATION-MANIFEST.md)，同类项目比较和拒绝吸收的能力见 [`RESEARCH-ECOSYSTEM.md`](RESEARCH-ECOSYSTEM.md)。

## 先看这里：安装前提和文档入口

本项目面向 Windows PowerShell，建议使用 Node.js 22 或更高版本。它可以在没有真实 DSH 服务的情况下运行离线测试；启动真实 Web 页面、浏览器契约测试或 Host API 测试时，仍然需要相应的本机 DSH、Python、npx 或 Playwright 环境。

## 不懂代码也能启动：只做这三步

1. 安装 Node.js 22 或更高版本，然后在 PowerShell 进入仓库根目录。
2. 复制下面三行命令；第一次会安装测试依赖，启动时只安装本地 Debug 包：

   ```powershell
   Set-Location .\packages\dsh-plugin-debug
   npm ci --ignore-scripts
   .\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoBrowser
   ```

3. 看到 JSON 或窗口后，再打开 `http://127.0.0.1:3081`。如果你只是想检查文件，不想启动 DSH，运行：

   ```powershell
   npm test
   .\Test-DSHStandalone.ps1
   ```

更新已经安装过的本地插件时，先停止旧实例，再加 `-ForcePluginInstall`；不要直接重复启动后猜测源码是否已覆盖：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoBrowser
```

看到 `PASS` 表示这项检查通过；`UNAVAILABLE` 表示本机没有对应的 DSH/浏览器/Host 服务；`PARTIAL` 或 `WARN` 表示只有部分证据；`FAIL` 才表示检查本身失败。任何一个报告生成成功，都不等于真实生产 DSH 已经恢复。

- 想先启动：看下面的“安装与启动”。
- 想逐项了解动作、输入和安全边界：阅读 [`packages/dsh-plugin-debug/README.zh-CN.md`](packages/dsh-plugin-debug/README.zh-CN.md)。
- 想确认源码是否可公开：运行 [`scripts/Verify-Publication.ps1`](scripts/Verify-Publication.ps1)，再看 [`PUBLICATION-CHECKLIST.md`](PUBLICATION-CHECKLIST.md)。
- 想增加功能或发版：按“如何更新功能”执行；不要直接编辑构建产物，也不要把测试运行时目录上传。

## 已合并的模块

| 原能力方向 | 单包中的实现 | 主要入口 |
| --- | --- | --- |
| 来源追踪（Provenance）与页面来源标注 | Web 客户端桥接、鼠标来源、Slot/Module 证据 | `lib/client.js`、`DSH-Provenance.ps1 -Action provenance` |
| 主机端（Host）诊断 | 上下文、插件健康、会话（Session）健康、安全审计、资源压力 | `tools/DSH-ProvenanceSuite.ps1`、`tools/Get-DSH-PluginHealth.ps1` |
| 事故取证 | 多层组件、启动回执、指针证据、Trace、完整性哈希 | `tools/DSH-Incident.ps1` |
| 客户端诊断时间线 | 有界 breadcrumb 环形缓冲、事件去重、丢弃计数和脱敏导出 | `lib/client.js`、`__DSH_PLUGIN_DEBUG__.getDiagnosticBreadcrumbs()` |
| 崩溃防护（Crash Guard）与监督器（Supervisor） | 启动失败识别、明确安全候选隔离、一次受控重启、页面通知 | `tools/Start-DSH.ps1`、`tools/DSH-Guard.psm1` |
| 快照与恢复（Snapshot/Recovery） | Profile/Workspace 快照、known-good 检查点、追加式会话分支；敏感条目和 `.env` 只记录排除原因、不复制内容 | `tools/DSH-Recovery.psm1`、`tools/DSH-KnownGood.psm1` |
| 受限修复（Repair） | 受限计划、receipt、pre/post hash、冲突时 `ROLLBACK_CONFLICT` | `tools/DSH-Repair.psm1`、`tools/DSH-SelfRepair.ps1` |
| 追踪与复现（Trace/Repro） | 仅元数据 Trace、baseline、autopsy、脱敏 repro 导出 | `tools/DSH-Trace*.psm1`、`tools/DSH-Repro.ps1` |
| 插件二分定位 | 只读生成安全第三方候选顺序和人工复核步骤 | `tools/DSH-Bisect.ps1`、`-Action plugin-bisect-plan` |
| 诊断报告对比 | 比较两次脱敏事故/诊断报告的状态、计数和 Issue code；敏感字段自动转人工复核 | `tools/DSH-DiagnosticsDiff.ps1`、`-Action diagnostics-diff` |
| 插件静态预检 | 离线扫描静态 `inject` 和 `ctx.*` 服务依赖，不执行插件代码 | `tools/DSH-Preflight.ps1`、`-Action plugin-preflight` |
| 依赖图检查 | 离线读取 Profile/package metadata，识别缺失依赖、循环和未引用本地包 | `tools/DSH-DependencyGraph.ps1`、`-Action plugin-dependency-graph` |
| Trace 循环分析 | 在有限窗口内识别重复工具调用/事件指纹，输出脱敏的事后复核线索 | `tools/DSH-TraceLoop.ps1`、`-Action trace-loop` |
| Trace 递归分析 | 按有限生命周期深度识别 Agent/Workflow 嵌套过深、未闭合和错配事件 | `tools/DSH-TraceRecursion.ps1`、`-Action trace-recursion` |
| 任务守护（Guardian） | 运行时观察工具调用循环、子任务递归和中断，发送一次脱敏提示，并对事件日志做有界轮转 | `lib/task-guardian.js`、`/api/dsh-plugin-debug/guardian/status` |
| 一键启动 | PowerShell/CMD/VBS 入口、端口冲突隔离、启动处置回执 | `Start-DSH-Debug.*`、`Start-DSH-Combined.*` |

## 安装与启动

在 Windows PowerShell 中从包目录运行：

```powershell
Set-Location .\packages\dsh-plugin-debug
.\Start-DSH-Debug.ps1 -NoBrowser
```

默认使用 `debug` Profile 和 `127.0.0.1:3081`。启动器只安装本地 Debug bundle，不搜索、安装或调用插件商店。也可以使用 DSH CLI 离线安装：

```powershell
dsh plugin --profile debug add . --offline
```

启动器会读取当前 Profile manifest 和插件 inventory。只有能被当前 manifest 明确映射、并且属于安全第三方扩展的失败插件才可能进入可逆 Guard patch；`@deepseek-ai/*` 核心包、runtime include、未知 ID 和证据冲突项都不会自动禁用。最多进行一次受控重启，第二次仍失败就进入 `degraded`，不会无限自愈。

每次启动会在 StateRoot 生成脱敏的 `startup-incident.json`，记录 `healthy`、`restarting`、`recovered`、`degraded` 或 `failed`、关联 ID、重启次数和隔离插件 ID。它不保存原始日志、Tool 参数、凭据或完整路径；`incident-capture` 会把这份回执作为启动组件证据读取。

页面诊断还维护一条本地有界时间线，记录启动处置、鼠标来源变化、插件清单刷新、Slot 错误和客户端错误的脱敏元数据。默认最多保留 80 条，超出后丢弃最旧事件并在报告中记录 `dropped` 数量；不会记录 Tool 参数、Tool 结果正文、DOM 文本、Cookie、Token 或请求正文。导出的诊断报告和 `__DSH_PLUGIN_DEBUG__.getDiagnosticBreadcrumbs()` 都会保留这条时间线，方便按顺序复核故障。

## 常用命令

```powershell
# 只读插件健康检查
.\Debug-DSH.ps1 -Action plugin-health -Profile debug -SkipApi

# 采集跨层脱敏事故包
.\Debug-DSH.ps1 -Action incident-capture -Profile debug -IncidentPath .\state\incident.json

# 生成安全插件二分计划，不改 Profile、不禁用插件、不执行命令
.\Debug-DSH.ps1 -Action plugin-bisect-plan -InputPath .\tools\fixtures\plugin-bisect-plan.json -BisectPath .\state\plugin-bisect-report.json

# 对比两次脱敏诊断报告；只输出元数据差异，遇到敏感字段返回 MANUAL_REVIEW
.\Debug-DSH.ps1 -Action diagnostics-diff -InputPath .\state\before-incident.json -InputPath .\state\after-incident.json -DiffPath .\state\incident-diff.json

# 检查 Trace 并运行本地回归 case
.\Debug-DSH.ps1 -Action trace-contract -InputPath .\tools\fixtures\tool-call-trace.json
.\Debug-DSH.ps1 -Action trace-eval -InputPath .\tools\fixtures\tool-call-trace.json -CasePath .\tools\fixtures\tool-call-case.json
.\Debug-DSH.ps1 -Action trace-loop -InputPath .\tools\fixtures\trace-loop.json -WindowSize 12 -RepeatThreshold 3
.\Debug-DSH.ps1 -Action trace-recursion -InputPath .\tools\fixtures\trace-recursion.json -MaxDepth 3

# 查看和恢复 known-good 检查点；恢复必须显式确认
.\Debug-DSH.ps1 -Action known-good-list -Profile debug
.\Debug-DSH.ps1 -Action known-good-restore -Profile debug -SnapshotId <id> -Force
```

任务守护默认是观察式能力：它只读取 Host 已经发出的生命周期事件，给重复 Tool Call 和过深的 Agent/Workflow 嵌套生成稳定指纹和短提示。它不会终止任务、杀进程、重启 Host、禁用插件或修改 Profile；可通过插件设置把 `policy` 改为 `report`，只记录不发送提示。状态接口只返回脱敏计数和最近事件：

```powershell
Invoke-RestMethod http://127.0.0.1:3081/api/dsh-plugin-debug/guardian/status
```

事件文件默认位于 `$DSH_HOME/guardian/events.jsonl`。内存中的最近事件窗口、单条事件元数据和磁盘事件日志均有界：默认保留当前文件加两个轮转文件，每个文件最多 256 KiB；可通过 Guardian 设置中的 `eventLogMaxBytes`（1 KiB–4 MiB）和 `eventLogMaxFiles`（2–10）调整。轮转只处理 Debug 自己的 `guardian/events.jsonl*` 文件，不读取或清理其他 DSH 数据。工具参数中的敏感字段会被替换，原始 Session ID 不会返回；长期运行时仍不要把本地日志提交或上传。若 Host 没有 `agent` 或 `session/event` 事件服务，守护会保持可加载但不报告，不会阻塞插件启动。

也可以用统一入口检查是否适合重启；离线输入和真实接口都走同一份边界：

```powershell
.\Debug-DSH.ps1 -Action guardian-status -Profile debug -Port 3081
.\tools\Test-DSHGuardianStatus.ps1
```

插件二分计划的输入必须是脱敏 JSON，包含 `inventory`、失败证据和 Profile manifest。输出只包含插件 ID、映射方式、`safe`/`protected`/`ambiguous` 分类、证据摘要和人工步骤。`safe` 只表示可以安全列入人工试验顺序，不等于已经证明根因。

`diagnostics-diff` 接受两份脱敏事故或诊断报告，只比较状态、结果、计数和安全格式的 Issue code。它不保存原始消息、路径、命令、Tool 参数或结果正文；一旦发现这些字段，结果为 `MANUAL_REVIEW`，不尝试猜测差异。

## 安全边界

- 默认离线；不上传日志，不连接 Langfuse/OpenTelemetry，也不创建插件市场（marketplace）。
- 默认只收集元数据（metadata-only）；不保存 Tool 参数、Tool 结果正文、会话正文、Cookie、Authorization、API key、`.env` 内容或完整工作目录。
- Guardian 本身是 observer-only，但整个包不是无副作用工具：Crash Guard/Runtime Supervisor 可能停止已确认的 DSH 子进程、写入可逆 Guard state/patch，并最多执行一次受控重启；底层 `Start-DSH.ps1` 默认关闭该处置能力，公开 Debug 启动器才会显式开启。
- Host API 默认只接受 loopback；远端 Host 必须通过 `DSH_DEBUG_API_ALLOWED_HOSTS` 明确列入主机白名单，禁止把不可信 `BaseUrl` 直接用于 session/history 查询。
- Recovery 对敏感文件只记录“存在但排除”，不会复制或恢复 `.env` 内容；公开 trace fixture 只保留调用键名、权限枚举、错误代码和事件顺序等元数据。
- 受限修复（Repair）只允许经过允许列表（allowlist）的本地 Guard 状态；递归危险字段、核心包、Profile/workspace 路径和未观察候选都会被拒绝。
- 回滚前校验修改前哈希（pre-image hash），回滚时校验修改后哈希（post-image hash）；用户改过文件就返回 `ROLLBACK_CONFLICT`，不覆盖改动。
- `UNAVAILABLE`（不可用）、`PARTIAL`（部分结果）、`WARN`（警告）和 `FAIL`（失败）都是有意保留的证据状态；生成报告不等于 DSH 已恢复，发现失败插件也不等于已经证明因果。
- 工作区恢复不删除快照之后新建的文件，不跟随 junction/symlink；敏感条目和 `.env` 不进入快照，也不会被恢复覆盖；会话分支（Session fork）保留原会话，不撤销已经执行的外部副作用。

## 测试程序

测试源码、PowerShell 回归脚本和脱敏 fixture 会随 GitHub 源码发布，别人可以直接查看“插件是怎么测试的”。发布边界检查必须在仓库根目录运行；包测试在包目录运行：

```powershell
# 1. 在仓库根目录：检查只发布单包，并拒绝日志、凭据和 node_modules
Set-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1

# 2. 在包目录：安装仅用于测试的依赖（不会执行安装脚本）
Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm test
npm run check
npm run check:standalone
npm run check:integration
```

下面这些离线回归不需要真实 DSH；它们会在临时目录中生成合成 Profile、workspace 或 fake runtime：

```powershell
.\tools\Test-DSHBisect.ps1
.\tools\Test-DSHDiagnosticsDiff.ps1
.\tools\Test-DSHPreflight.ps1
.\tools\Test-DSHDependencyGraph.ps1
.\tools\Test-DSHTraceLoop.ps1
.\tools\Test-DSHTraceRecursion.ps1
.\tools\Test-DSHGuardianStatus.ps1
.\tools\Test-DSHCrashGuard.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1
.\tools\Test-DSHLauncherConflict.ps1
.\tools\Test-DSHPluginIntegration.ps1
.\tools\Test-DSHProvenanceIntegration.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
.\tools\Test-DSHRepro.ps1
.\tools\Test-DSHSelfRepair.ps1
```

其中 Crash Guard、Runtime Supervisor、启动冲突和集成回归会启动受控的临时 fake 进程或 loopback fixture；它们不会操作真实 DSH，但也不能称为纯静态检查。若只做无服务的安全回归，可先运行 `Test-DSHGuard.ps1 -SkipApi`、`Test-DSHRecovery.ps1`、`Test-DSHGuardianStatus.ps1` 和 Node `npm test`。

下面这些测试覆盖更完整的恢复、取证和 API 分支；如果本机没有对应服务，会返回 `UNAVAILABLE` 或按脚本说明跳过，不得把静态 fixture 当成真实线上验证：

```powershell
.\tools\Test-DSHGuard.ps1 -SkipApi
.\tools\Test-DSHPluginHealth.ps1
.\tools\Test-DSHPluginState.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHKnownGood.ps1
.\tools\Test-DSHIncidentCorrelation.ps1
.\tools\Test-DSHTraceProfile.ps1
.\tools\Test-DSHTraceAutopsy.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHLiveApi.ps1
```

`Test-DSHStandalone.ps1` 会检查包内脚本是否齐全、PowerShell 是否可解析、统一入口是否能传递命名参数、插件二分的保护/隐私契约、Crash Guard 的可逆隔离、启动回执、repair 冲突回滚、Trace 递归的失败即停止边界和所有临时目录清理。Node 测试还覆盖任务守护的循环检测、递归检测、状态接口、脱敏和“绝不终止任务”契约。测试只使用临时 Profile、临时 workspace 和合成数据，不会停止现有 DSH，也不会修改真实用户 Profile。

`Test-DSHPointerBrowser.ps1` 需要本机有 Python、npx 和可用的 Playwright 浏览器运行时；缺少浏览器时报告 `UNAVAILABLE`，不会把静态 HTML 冒充真实 DSH Web 验证。静态检查通过也不等于生产 DSH、外部服务或 GitHub 页面已经运行验证。

## 如何更新功能

1. 先在 `src/`、`tools/`、入口脚本和测试中修改源码；不要手工编辑 `lib/` 和 `bundle-manifest.json`。
2. 每个新能力同时加入一个可脱敏的回归 fixture、一个正常路径断言和一个失败路径断言，写清楚它不会执行什么、不会写什么。
3. 如果功能改变了公开行为，先按语义化版本（SemVer）修改 `package.json`，同步 `package-lock.json`；不要在构建完成后才改版本。
4. 运行 `npm test`、`npm run check`、`npm run check:standalone`、`npm run check:integration`，再运行相关 PowerShell 测试和根目录 `scripts/Verify-Publication.ps1`。
5. 运行 `npm pack --dry-run --json --ignore-scripts`，把实际文件数同步到 `RELEASE-MANIFEST.json` 和 `SOURCE-SNAPSHOT.md`。
6. 先检查 `git diff --check`、敏感文件和待提交文件；完成一次本地可审阅提交后，从 fresh clone（全新克隆）重跑测试，最后才 push 到 `main`。
7. 发布后再读取远端提交哈希，并把 `RELEASE-MANIFEST.json` 的发布字段和 `SOURCE-SNAPSHOT.md` 更新为事实；不能用旧提交哈希冒充新版本。

不要把 `node_modules`、`.dsh`、`.codex`、Profile state、logs、coverage、credentials、临时 fake runtime 或测试输出提交进仓库。功能继续扩展时，必须保持单包边界、默认离线、仅元数据和失败即停止（fail-closed）的安全契约。

## GitHub 自动维护现在已经打开什么

- `DSH Debug Plugin CI`：提交、Pull Request、手动触发和每周定时运行；包含 Node、Windows PowerShell、发布边界和 fresh clone 门禁。
- `CodeQL`：扫描 JavaScript/TypeScript 和 GitHub Actions workflow；它只报告安全问题，不会改变插件运行时。
- `Dependabot`：每月检查插件依赖、固定 runtime 依赖和 Actions 版本，生成可审阅的更新 PR。
- GitHub 依赖漏洞告警和自动安全修复：已在仓库设置中打开。
- Issue/PR 模板：诊断报告、功能建议和隐私/测试检查都放在仓库根目录的 `.github/` 下，GitHub 页面会真正读取这些文件。

这些自动化也不能替代本地测试、真实 DSH/浏览器验证或人工审阅；看到 CI 变绿时，仍要看它覆盖的是哪一层。

## 当前开源边界

当前只发布 `packages/dsh-plugin-debug` 一个 MIT 包。`dsh-plugin-store` 不在包内，也不在项目目录中；旧 provenance、debug-suite 和 one-click 目录已从项目树删除，发布流程不会恢复第二个插件。详细发布门禁见 [`PUBLICATION-CHECKLIST.md`](PUBLICATION-CHECKLIST.md)、[`PUBLISHING.md`](PUBLISHING.md) 和 [`SECURITY.md`](SECURITY.md)。

## 许可证

MIT，版权归 `shine-233`。
