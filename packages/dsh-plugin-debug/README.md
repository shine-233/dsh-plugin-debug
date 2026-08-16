# dsh-plugin-debug（DSH 调试插件）

这是 npm 和 GitHub 默认显示的中文说明。它把 DSH 检测、调试、恢复、插件健康检查、崩溃隔离、事故取证、Trace 分析、任务守护和一键启动能力合并到一起，运行时只有一个包：`dsh-plugin-debug`。更长的逐项中文手册见 [`README.zh-CN.md`](README.zh-CN.md)；两份文档都以当前源码和测试为准，不把英文术语当成额外组件。

本包不依赖插件商店，也不会安装或调用 `dsh-plugin-store`。旧的 provenance、debug-suite 和 one-click 目录已经迁移后从项目树移除；已有旧 provenance Profile 需要显式迁移或重新安装。候选发布状态、实际 npm 文件清单和 GitHub 推送状态分别以仓库根目录的 [`RELEASE-MANIFEST.json`](../../RELEASE-MANIFEST.json)、[`SOURCE-SNAPSHOT.md`](../../SOURCE-SNAPSHOT.md) 和远端提交为准。

## 适用范围

它适合在 Windows PowerShell 中排查以下问题：

- DSH Profile、bundle、patch 或本地运行时（runtime）清单不一致；
- Web 启动失败、第三方插件加载失败、启动后反复崩溃；
- 页面元素的插件来源不清楚、Slot/Module 归属冲突；
- Tool Call、权限元数据、会话（Session）历史或上下文装载异常；
- 需要生成脱敏事故包、Trace baseline、可逆快照或受限修复（repair）回执。

诊断输出是证据和线索，不会把“发现失败插件”写成已经证明根因，也不会把“报告写入成功”写成 DSH 已经恢复。

## 安装与一键启动

从本目录运行：

```powershell
.\Start-DSH-Debug.ps1 -NoBrowser
```

默认使用 `debug` Profile、`127.0.0.1:3081`，并离线安装本地 bundle。也可以直接使用 DSH CLI：

```powershell
dsh plugin --profile debug add . --offline
```

`Start-DSH-Combined.*` 是可选的 Agent 覆盖层（overlay）入口。只有显式运行 `tools\Install-DSH-Agents.vbs` 后才会安装覆盖层；它不是 Debug 运行时依赖，也不是插件商店。

## 能力总览

| 能力 | 提供内容 | 重要边界 |
| --- | --- | --- |
| 页面来源标注 | 读取 data-dsh-plugin、data-dsh-module、CSS、Slot，显示插件、Module、Slot 和证据等级 | 未标记的 DOM 显示未知，不猜测来源 |
| 主机端（Host）诊断 | 上下文、插件健康、会话（Session）健康、安全审计、资源压力、失败归档 | API 不可用时保留 PARTIAL/UNAVAILABLE |
| 崩溃防护（Crash Guard） | 启动日志和 inventory 识别安全第三方候选，写入可逆 patch，最多重启一次 | DSH 核心包、runtime include、未知或歧义项不自动禁用 |
| 启动回执 | 写入 startup-incident.json，记录启动状态、关联 ID、重启次数和隔离插件 | 不写原始日志、Tool 参数、凭据或完整路径 |
| 客户端诊断时间线 | 80 条上限的脱敏 breadcrumb 环形缓冲，记录启动、鼠标来源、插件清单、Slot 和客户端错误顺序 | 超出上限记录 dropped；不保存 Tool 参数、正文、DOM 文本或凭据 |
| 快照/恢复（Snapshot/Recovery） | Profile、Workspace、known-good 检查点和追加式会话分支 | 不删除快照之后新文件，不重写原会话 |
| 受限修复（Repair） | 受限计划、allowlist、pre/post-image hash、receipt 和冲突回滚 | 用户改过文件时返回 ROLLBACK_CONFLICT，不覆盖改动 |
| 追踪/事故（Trace/Incident） | 仅元数据 Trace、baseline、autopsy、跨层事故包和 repro 导出 | 不保留 Tool 参数、结果正文、会话正文、Cookie 或 token |
| 插件二分定位 | 根据脱敏 inventory、失败证据和 manifest 生成候选顺序与人工步骤 | 只读计划，不自动禁用、不写 Profile、不执行命令 |
| 诊断报告对比 | 比较两次诊断/事故报告的状态、计数和 Issue code | 发现消息、路径、命令或凭据字段时返回 `MANUAL_REVIEW` |
| 插件静态预检 | 离线扫描 JS/MJS/CJS 的静态 `inject` 声明和 `ctx.*` 服务使用 | 不执行插件代码；动态访问和超出扫描上限转 `MANUAL_REVIEW` |
| 依赖图检查 | 读取 Profile/package manifest 和已有 package metadata，报告缺失依赖、循环和未引用本地包 | 不安装、不执行 package code、不修改 Profile；核心 DSH 包受保护 |
| Trace 循环与递归分析 | 在有界窗口/深度内识别重复调用和 Agent/Workflow 嵌套；输出脱敏事后线索 | 不阻塞运行时、不创建 Session、不执行 Tool；非法或不完整输入失败即停止 |
| 任务守护（Guardian） | 观察运行中的 Tool Call、子任务递归和中断，必要时发送一次短提示并提供状态接口 | observer-only：不终止任务、不杀进程、不重启 Host、不禁用插件、不修改 Profile |

## 启动故障处理和页面通知

启动器按以下顺序工作：

1. 读取当前 Profile manifest、插件 inventory 和启动日志。
2. 只接受 manifest 明确映射的安全第三方插件候选。
3. 为已经观察到失败的候选写入 `guard-state.json` 和 `guard.patch.yml`。
4. 最多进行一次受控重启，并重新等待 Web ready。
5. 第二次仍失败时返回 `degraded` 或 `failed`，不会无限重试。

如果端口已经被其他 DSH 实例占用，启动器不会杀进程、覆盖 Profile 或强行接管端口；它会在可用时选择隔离 Profile 和 loopback 端口。页面通知只报告观察到的故障，不把相关性伪装成因果结论。通知本身不执行禁用、不执行命令，也不把“发现失败插件”写成“已经证明根因”。

页面只有在 Host 同时声明 `diagnosticSessionPolicy.automatic=true` 和 `mode=no-tools` 时，才允许自动创建隔离的诊断规划会话（Session）。普通 rc.6 Host 没有这个能力时返回 `UNAVAILABLE`，不会创建普通的可执行会话；用户已有会话、工具调用、审批事件和过期证据也会被拒绝。

## 插件二分定位、报告对比和静态预检

输入是脱敏 JSON，至少包含：

- profileManifest 或 manifest；
- inventory 或 pluginInventory.entries；
- failureEvidence、failures 或 evidence。

运行：

```powershell
.\Debug-DSH.ps1 -Action plugin-bisect-plan -InputPath .\tools\fixtures\plugin-bisect-plan.json -BisectPath .\state\plugin-bisect-report.json

# 对比两次脱敏诊断报告，只输出元数据差异
.\Debug-DSH.ps1 -Action diagnostics-diff -InputPath .\state\before.json -InputPath .\state\after.json -DiffPath .\state\diff.json
```

报告中的候选分为：

- safe：当前 manifest 能明确映射到安全第三方插件，可列入人工试验顺序；
- protected：DSH 核心包、runtime 或普通依赖，不能作为自动隔离候选；
- ambiguous：ID 无法映射、重复或证据不足，必须人工复核。

每一步都标记 `humanApprovalRequired=true`、`executesCommand=false`、`changesProfile=false` 和 `changesWorkspace=false`。`safe` 只是安全候选分类，不是根因证明。

`diagnostics-diff` 是离线、只读的比较器。它只保留 `status`、`result`、`count`、`schemaVersion` 和安全格式的 Issue code；不读取或输出原始消息、完整路径、URL、命令、Tool 参数、结果正文、Cookie、Token 或凭据。如果任一输入违反这个边界，比较会停止并返回 `MANUAL_REVIEW`。

静态插件预检只读取指定的 JS/MJS/CJS 文件，移除注释和字符串后检查 `ctx.*` 服务是否在静态 `inject` 列表中；它不会 import、require 或执行目标插件。无法静态确定的动态 `ctx[...]`、动态 inject、文件数量/大小上限会进入 `MANUAL_REVIEW`，不自动修改插件或 Profile：

```powershell
.\Debug-DSH.ps1 -Action plugin-preflight -InputPath .\path\to\plugin -PreflightPath .\state\preflight.json
```

依赖图检查同样是离线只读分析，接受包含 `profileManifest`/`manifest` 和可选 `packages` 元数据（metadata）的 JSON，不调用 npm、pnpm 或 DSH CLI：

```powershell
.\Debug-DSH.ps1 -Action plugin-dependency-graph -InputPath .\tools\fixtures\plugin-dependency-graph.json
```

Trace 递归分析按生命周期事件计算有限嵌套深度。它只接受递增序号和明确的 `agent`/`workflow` 开始与结束标记；动态、错配或未闭合事件返回 `MANUAL_REVIEW`，超过事件上限或输入损坏返回 `FAIL`。输出只包含事件数量、深度、序号和分类，不回显 Agent ID、Session ID、消息或 Tool 参数：

```powershell
.\Debug-DSH.ps1 -Action trace-recursion `
  -InputPath .\tools\fixtures\trace-recursion.json `
  -MaxDepth 3

.\tools\Test-DSHTraceRecursion.ps1
```

任务守护是包内的运行时观察器。默认 `policy=auto` 时，在冷却窗口内最多给同一 Session 发送一次脱敏指导；`policy=report` 只记录发现，不发送指导。它使用 Tool 名称和经过敏感字段替换的参数形状生成 SHA-256 指纹，状态接口为 `/api/dsh-plugin-debug/guardian/status`。内存中的最近事件窗口和每条事件元数据有界；`$DSH_HOME/guardian/events.jsonl` 当前按行追加且没有自动轮转，因此不保证整个事件文件大小有界。状态和事件报告不会返回原始 Session ID、原始 Tool 参数或正文；长期运行时请按自己的保留策略管理本地日志。如果 Host 没有 `agents` 服务或对应事件服务，插件仍可启动但守护保持空闲。

重启前可用统一入口读取状态；空闲返回 0 和 `SAFE_TO_RESTART`，有活动 Session 或未完成操作返回 2 和 `BUSY_DO_NOT_RESTART`，不会替你执行重启：

```powershell
.\Debug-DSH.ps1 -Action guardian-status -Profile debug -Port 3081
.\tools\Test-DSHGuardianStatus.ps1
```

Trace loop 分析只在有限窗口内比较脱敏事件的稳定签名，输出重复次数和索引，不输出消息、路径、命令或 Tool 参数；检测到敏感字段时返回 `MANUAL_REVIEW`：

```powershell
.\Debug-DSH.ps1 -Action trace-loop -InputPath .\tools\fixtures\trace-loop.json -WindowSize 12 -RepeatThreshold 3
```

## 公开的测试程序

测试脚本和脱敏 fixture 会随 GitHub 源码发布，便于别人检查实现和复现边界。先在仓库根目录执行发布边界检查，再进入包目录执行包测试：

```powershell
# 仓库根目录：必须在安装依赖前检查发布边界
Set-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1

# 包目录：只安装测试所需依赖；--ignore-scripts 不执行安装脚本
Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm test
npm run check
npm run check:standalone
npm run check:integration
```

离线核心回归（使用临时目录和合成输入，不需要真实 DSH）：

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

恢复、取证和 API 分支（没有对应本机服务时按脚本输出 `UNAVAILABLE`，不能把静态 fixture 当成真实线上验证）：

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
# 可选：需要 Python、npx 和 Playwright 浏览器；缺失时返回 UNAVAILABLE
.\tools\Test-DSHPointerBrowser.ps1
```

`Test-DSHStandalone.ps1` 还会检查 Trace 循环/递归分析、插件二分的保护边界和隐私契约，以及：

- 所有公开入口、工具和 fixture 是否随包存在；
- PowerShell Parser 是否为零错误；
- Debug-DSH.ps1 是否能正确传递 Action、InputPath、开关和重复参数；
- 二分计划是否保护核心包、标记歧义、保持输入不变并且不泄露原始故障消息；
- Crash Guard 是否只隔离安全候选、写入可逆 patch 并生成 recovered 启动回执；
- Repair 是否拒绝递归危险字段，且在 post-image 变化时返回 ROLLBACK_CONFLICT；
- 临时 Profile、workspace、runtime、logs 和 state 是否在测试结束后清理。

Node 测试中的 `tests/task-guardian.test.js` 覆盖循环检测、递归深度、report 策略、状态路由、敏感参数脱敏、事件上限和 observer-only 契约；它不会启动真实 DSH，也不会写入用户 Profile。

所有回归使用临时目录和合成数据，不会停止现有 DSH，也不会修改真实用户 Profile。Test-DSHPointerBrowser.ps1 需要 Python、npx 和 Playwright 浏览器运行时；依赖缺失时报告 UNAVAILABLE，不会把静态 HTML 冒充真实 Web 验证。

## 如何更新功能和发版

1. 在 `src/`、`tools/`、入口脚本中修改源码，同时添加对应 Node/PowerShell 回归测试；每项新功能至少要有一个正常场景和一个拒绝/失败场景。
2. 不手工编辑 `lib/` 和 `bundle-manifest.json`，由 `npm run check` 重新构建并校验。
3. 按语义化版本（SemVer）更新 `package.json`，同步 `package-lock.json`；README、变更说明和实际行为必须一致。
4. 运行 `npm test`、`npm run check`、`npm run check:standalone`、`npm run check:integration`、`Test-DSHStandalone.ps1` 及相关工具测试。
5. 回到仓库根目录运行 `scripts/Verify-Publication.ps1`，确认只公开单包；再运行 `npm pack --dry-run --json --ignore-scripts`，把实际文件数量同步到 `RELEASE-MANIFEST.json` 和 `SOURCE-SNAPSHOT.md`。
6. 检查 `git diff --check`、敏感文件和待提交内容；先做本地可审阅提交，从 fresh clone（全新克隆）重跑测试后再 push。
7. push 后读取远端提交哈希，更新发布清单的发布字段；如果仍是候选状态，不要在 README 中宣称正式发布。

不要提交 `node_modules`、`.dsh`、`.codex`、Profile state、logs、coverage、credentials、临时 fake runtime 或测试输出。新功能必须继续保持默认离线、仅元数据（metadata-only）和失败即停止（fail-closed）安全契约；如果需要更高权限、联网或自动执行，先增加独立的安全评审和回归测试。

## 目录结构

```text
src/                         Web 客户端来源标注源码
lib/                         构建后的 DSH bundle
lib/task-guardian.js         运行时任务循环/递归观察器
DSH-Provenance.ps1           完整统一调度入口
Debug-DSH.ps1                简短公开入口
Start-DSH-Debug.*             Debug 调试一键启动入口
Start-DSH-Combined.*          Debug 调试 + 可选 Agent 覆盖层
tools/                       主机端诊断、恢复、Crash Guard、测试程序
tools/fixtures/              合成且脱敏的 trace、pointer、bisect 输入
tests/                       Node.js 运行时测试
```

GitHub 源码会保留这些测试脚本和 `tools/fixtures`，方便审阅和复现；npm/DSH 可发布包会排除运行时 `node_modules`、状态目录、日志、凭据和本机临时文件。两者不是同一份内容，查看包内容应以 `npm pack --dry-run --json --ignore-scripts` 为准。

## 许可证与旧模块

本包使用 MIT 许可证，版权归 shine-233。dsh-plugin-store 不在包内，也不在项目目录中；旧 provenance、debug-suite 和 one-click 源码已经迁移到本包后移除，当前不创建第二个公开插件，也不恢复插件商店。
