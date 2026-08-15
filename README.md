# dsh-plugin-debug

这是一个把我创作的 DSH 检测、调试、恢复、插件健康检查、崩溃隔离、事故取证、Trace 分析和一键启动能力合并后的单一开源插件。公开运行时包只有 `dsh-plugin-debug`，源码目录是 `packages/dsh-plugin-debug`。

GitHub 仓库：[shine-233/dsh-plugin-debug](https://github.com/shine-233/dsh-plugin-debug)

插件商店 `dsh-plugin-store` 没有进入这个包，也不再是运行时依赖。旧的 provenance、debug-suite 和 one-click 源码已经完成迁移并从项目目录移除；当前公开源代码的唯一事实来源是这个单包。具体名称和迁移记录见 [`MIGRATION-MANIFEST.md`](MIGRATION-MANIFEST.md)，同类项目比较和拒绝吸收的能力见 [`RESEARCH-ECOSYSTEM.md`](RESEARCH-ECOSYSTEM.md)。

## 已合并的模块

| 原能力方向 | 单包中的实现 | 主要入口 |
| --- | --- | --- |
| Provenance 与页面来源标注 | Web Client bridge、鼠标来源、Slot/Module 证据 | `lib/client.js`、`DSH-Provenance.ps1 -Action provenance` |
| Host 诊断 | 上下文、插件健康、Session 健康、安全审计、资源压力 | `tools/DSH-ProvenanceSuite.ps1`、`tools/Get-DSH-PluginHealth.ps1` |
| 事故取证 | 多层组件、启动回执、指针证据、Trace、完整性哈希 | `tools/DSH-Incident.ps1` |
| 客户端诊断时间线 | 有界 breadcrumb 环形缓冲、事件去重、丢弃计数和脱敏导出 | `lib/client.js`、`__DSH_PLUGIN_DEBUG__.getDiagnosticBreadcrumbs()` |
| Crash Guard 与 Supervisor | 启动失败识别、明确安全候选隔离、一次受控重启、页面通知 | `tools/Start-DSH.ps1`、`tools/DSH-Guard.psm1` |
| Snapshot 与 Recovery | Profile/Workspace 快照、known-good 检查点、追加式 Session 分支 | `tools/DSH-Recovery.psm1`、`tools/DSH-KnownGood.psm1` |
| Repair | 受限计划、receipt、pre/post hash、冲突时 `ROLLBACK_CONFLICT` | `tools/DSH-Repair.psm1`、`tools/DSH-SelfRepair.ps1` |
| Trace 与复现 | metadata-only Trace、baseline、autopsy、脱敏 repro 导出 | `tools/DSH-Trace*.psm1`、`tools/DSH-Repro.ps1` |
| 插件二分定位 | 只读生成安全第三方候选顺序和人工复核步骤 | `tools/DSH-Bisect.ps1`、`-Action plugin-bisect-plan` |
| 诊断报告对比 | 比较两次脱敏事故/诊断报告的状态、计数和 Issue code；敏感字段自动转人工复核 | `tools/DSH-DiagnosticsDiff.ps1`、`-Action diagnostics-diff` |
| 插件静态预检 | 离线扫描静态 `inject` 和 `ctx.*` 服务依赖，不执行插件代码 | `tools/DSH-Preflight.ps1`、`-Action plugin-preflight` |
| 依赖图检查 | 离线读取 Profile/package metadata，识别缺失依赖、循环和未引用本地包 | `tools/DSH-DependencyGraph.ps1`、`-Action plugin-dependency-graph` |
| Trace 循环分析 | 在有限窗口内识别重复工具调用/事件指纹，输出脱敏的事后复核线索 | `tools/DSH-TraceLoop.ps1`、`-Action trace-loop` |
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

# 查看和恢复 known-good 检查点；恢复必须显式确认
.\Debug-DSH.ps1 -Action known-good-list -Profile debug
.\Debug-DSH.ps1 -Action known-good-restore -Profile debug -SnapshotId <id> -Force
```

插件二分计划的输入必须是脱敏 JSON，包含 `inventory`、失败证据和 Profile manifest。输出只包含插件 ID、映射方式、`safe`/`protected`/`ambiguous` 分类、证据摘要和人工步骤。`safe` 只表示可以安全列入人工试验顺序，不等于已经证明根因。

`diagnostics-diff` 接受两份脱敏事故或诊断报告，只比较状态、结果、计数和安全格式的 Issue code。它不保存原始消息、路径、命令、Tool 参数或结果正文；一旦发现这些字段，结果为 `MANUAL_REVIEW`，不尝试猜测差异。

## 安全边界

- 默认离线；不上传日志，不连接 Langfuse/OpenTelemetry，也不创建 marketplace。
- 默认 metadata-only；不保存 Tool 参数、Tool 结果正文、会话正文、Cookie、Authorization、API key、`.env` 内容或完整工作目录。
- Repair 只允许经过 allowlist 的本地 Guard 状态；递归危险字段、核心包、Profile/workspace 路径和未观察候选都会被拒绝。
- 回滚前校验 pre-image hash，回滚时校验 post-image hash；用户改过文件就返回 `ROLLBACK_CONFLICT`，不覆盖改动。
- `UNAVAILABLE`、`PARTIAL`、`WARN` 和 `FAIL` 都是有意保留的证据状态；生成报告不等于 DSH 已恢复，发现失败插件也不等于已经证明因果。
- 工作区恢复不删除快照之后新建的文件，不跟随 junction/symlink；Session fork 保留原 Session，不撤销已经执行的外部副作用。

## 测试程序

测试源码、PowerShell 回归脚本和脱敏 fixture 会随 GitHub 源码发布，别人可以直接查看“插件是怎么被测试的”。从包目录运行：

```powershell
npm ci --ignore-scripts
npm test
npm run check
npm run check:standalone
npm run check:integration
.\tools\Test-DSHBisect.ps1
.\tools\Test-DSHDiagnosticsDiff.ps1
.\tools\Test-DSHPreflight.ps1
.\tools\Test-DSHDependencyGraph.ps1
.\tools\Test-DSHTraceLoop.ps1
.\tools\Test-DSHCrashGuard.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1
.\tools\Test-DSHGuard.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHSelfRepair.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
```

`Test-DSHStandalone.ps1` 会检查包内脚本是否齐全、PowerShell 是否可解析、统一入口是否能传递命名参数、插件二分的保护/隐私契约、Crash Guard 的可逆隔离、启动回执、repair 冲突回滚和所有临时目录清理。测试只使用临时 Profile、临时 workspace 和合成数据，不会停止现有 DSH，也不会修改真实用户 Profile。

`Test-DSHPointerBrowser.ps1` 需要本机有 Python、npx 和可用的 Playwright 浏览器运行时；缺少浏览器时报告 `UNAVAILABLE`，不会把静态 HTML 冒充真实 DSH Web 验证。静态检查通过也不等于生产 DSH、外部服务或 GitHub 页面已经运行验证。

## 如何更新功能

1. 只在 `src/`、`tools/`、入口脚本和测试中修改；不要手工编辑 `lib/` 和 `bundle-manifest.json`。
2. 每个新能力同时加入一个可脱敏的回归 fixture 和一个失败路径断言，明确它不会执行什么、不会写什么。
3. 运行 `npm run check`、`npm run check:standalone`、相关 PowerShell 测试和根目录 `scripts/Verify-Publication.ps1`。
4. 按 SemVer 修改 `package.json`，同步 `package-lock.json`；构建脚本会更新 `lib/` 和 `bundle-manifest.json`。
5. 运行 `npm pack --dry-run --json --ignore-scripts`，把新的文件数同步到 `RELEASE-MANIFEST.json` 和 `SOURCE-SNAPSHOT.md`。
6. 先检查 `git diff --check`、敏感文件和待提交文件，再提交并从 fresh clone 重跑测试，最后 push 到 `main`。

不要把 `node_modules`、`.dsh`、`.codex`、Profile state、logs、coverage、credentials、临时 fake runtime 或测试输出提交进仓库。功能继续扩展时，必须保持单包边界和现有 fail-closed 安全契约。

## 当前开源边界

当前只发布 `packages/dsh-plugin-debug` 一个 MIT 包。`dsh-plugin-store` 不在包内，也不在项目目录中；旧模块已迁移后删除并保留在 Windows 回收站作为可恢复备份，不会自动恢复。详细发布门禁见 [`PUBLICATION-CHECKLIST.md`](PUBLICATION-CHECKLIST.md)、[`PUBLISHING.md`](PUBLISHING.md) 和 [`SECURITY.md`](SECURITY.md)。

## 许可证

MIT，版权归 `shine-233`。
