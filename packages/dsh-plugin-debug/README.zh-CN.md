# DSH Debug Plugin（DSH 调试插件）

这是单包 `dsh-plugin-debug` 的完整中文手册。它把 DSH 检测、调试、来源追踪、日志取证、恢复、崩溃防护（Crash Guard）、插件预检、Trace 分析、任务守护和一键启动能力合并到一起；不依赖插件商店，也不会安装或调用 `dsh-plugin-store`。包内默认的 [`README.md`](README.md) 也是中文简版，GitHub 首页不会要求读者先阅读英文文档。

本手册说明当前源码能做什么、明确不会做什么，以及如何测试、更新和发布。候选版本是否已经推送，以仓库根目录的 [`RELEASE-MANIFEST.json`](../../RELEASE-MANIFEST.json)、[`SOURCE-SNAPSHOT.md`](../../SOURCE-SNAPSHOT.md) 和远端提交为准；本地测试通过不等于生产 DSH 已验证。

建议环境：Windows PowerShell、Node.js 22 或更高版本。离线核心测试不需要真实 DSH；页面、浏览器和 Host API 测试需要额外的本机运行环境。

## 这个插件解决什么问题

- 启动前检查 Profile、bundle、patch、运行时（runtime）和本地依赖是否一致。
- DSH 启动失败或 Web ready 后发现第三方插件失败时，生成可逆的 `disabled: true` Guard patch，并最多进行一次受控重启。
- 启动冲突时不杀掉已有 DSH，也不覆盖已有 Profile；默认切换到新的 loopback 端口和隔离 Profile。
- 在 Web 页面提供鼠标来源检查器和诊断页，报告插件、Module、Slot、客户端错误、主机端（Host）插件清单、Tool Call 元数据和运行时线索。
- 在客户端保留最多 80 条脱敏诊断 breadcrumb（面包屑事件），串起启动处置、鼠标来源变化、插件清单刷新、Slot/客户端错误；超出上限会记录丢弃计数，不保存 Tool 参数、正文、DOM 文本或凭据。
- 比较两次脱敏诊断/事故报告的状态、计数和 Issue code；检测到消息、路径、命令或凭据字段时只返回 `MANUAL_REVIEW`。
- 提供 Profile/Workspace 快照（snapshot）、known-good 恢复、事故采集（incident capture）、脱敏 trace/eval、资源压力和失败归档工具。
- 根据脱敏插件清单、失败证据和 Profile manifest 生成只读插件二分定位计划，给出安全第三方候选顺序；不会自动禁用插件、不会写 Profile、不会执行命令。
- 离线静态预检 JS/MJS/CJS 的 `inject` 与 `ctx.*` 服务依赖；不执行插件代码，动态访问或超出扫描上限时只返回人工复核。
- 根据 Profile/package 元数据（metadata）生成离线依赖图，报告缺失依赖、循环和未引用本地包；不运行 npm/pnpm、不安装依赖、不执行 package code。
- 对脱敏 Trace 事件做有限窗口的重复循环分析；只输出重复次数、索引和稳定签名，敏感字段会转人工复核。
- 对 Agent/Workflow 生命周期做有界递归分析；深度超限返回 `RECURSION_DETECTED`，动态、错配或未闭合标记返回 `MANUAL_REVIEW`，不回显 ID 或正文。
- 运行时任务守护观察 Tool Call 循环、子任务递归和中断；默认只在冷却窗口内发送一次脱敏提示，永远不终止任务、杀进程、重启 Host、禁用插件或修改 Profile。
- 在 Host 明确声明 no-tools planner 能力时，才允许创建隔离的修复规划 Session；普通 Host 上保持 `UNAVAILABLE`，不会偷偷创建一个带工具的 Session。

诊断结果是证据和线索，不会把“发现失败插件”夸大成已经证明根因，也不会把“报告写入成功”夸大成 DSH 已经恢复。

## 安装

使用仓库中的一键入口：

```powershell
.\Start-DSH-Debug.ps1 -NoBrowser
```

默认使用 `debug` Profile 和 `127.0.0.1:3081`，首次运行把当前目录中的 bundle 离线安装到该 Profile。需要后台运行时使用 `Start-DSH-Debug.vbs`。启动器只读取本地包，不搜索、安装或调用插件商店。

也可以通过 DSH CLI 安装本地包：

```powershell
dsh plugin --profile debug add . --offline
```

`Start-DSH-Combined.*` 只在你先运行 `tools\Install-DSH-Agents.vbs` 后才会启用可选的 Kimi/Codex Agent 覆盖层（overlay）；覆盖层不是 Debug 核心依赖。

## 启动故障处理

启动器默认开启一次性 Crash Guard。它遵守以下顺序：

1. 读取当前 Profile 的插件清单和安全候选。
2. 只考虑明确属于第三方插件、且能由当前 Profile manifest 映射的候选；核心 `@deepseek-ai/*` 和 runtime `include` 项不会自动禁用。
3. 对启动日志或 `pluginInventory/list` 已观察到的失败插件写入 Guard state 和可逆 patch。
4. 最多重启一次并重新等待 Web ready；第二次仍失败时进入 `degraded`，不会无限自愈。

因此“有问题就直接禁用”不是无条件删除：它只自动隔离有明确证据的安全第三方候选，无法归因时保留人工复核。

每次启动还会在当前 `StateRoot` 写入 `startup-incident.json` 启动处置回执。它记录本次启动是 `healthy`、`restarting`、`recovered`、`degraded` 还是 `failed`，以及关联 ID、重启次数、被隔离的插件 ID 和可查看的本地证据文件名。回执不写原始日志、Tool 参数、凭据或完整路径；`incident-capture` 会在存在时把它纳入 `components.startup`，方便后续诊断和复现。

如果目标端口已有其他 DSH 实例，而目标 Profile 尚未安装 Debug bundle，启动器默认自动使用类似 `web-debug-3082` 的隔离 Profile。原实例、原端口和原 Profile 不会被修改。要恢复严格拒绝模式，可传：

```powershell
.\tools\Start-DSH.ps1 -NoIsolateOnConflict -NoErrorDialog
```

## 页面通知和修复 Session

Web Client 会把 Host inventory 中的 failed plugin、动态插件运行错误和 Slot 渲染错误显示在诊断页，并持续刷新运行时状态。页面提示只报告“发现了什么”，不会伪造因果结论。

诊断页还会显示本地时间线。它是一个固定上限的环形缓冲，事件只有类别、时间、状态、插件/Module/Slot 标识和经过脱敏的短摘要；`getDiagnosticBreadcrumbs()` 与导出的诊断 JSON 会同时返回 `limit`、`dropped` 和 `truncated`，便于判断是否因为事件太多而丢失早期线索。

修复规划默认是只读 dry-run：

```powershell
.\Debug-DSH.ps1 -Action repair-assist -Profile debug -Port 3081
```

只有 `host.describe` 明确声明 no-tools planner 能力时，这个动作才会创建隔离的最小 Session；它会拒绝已有用户 Session、工具调用、审批事件、执行事件、未知字段和过期证据。当前 DSH rc.6 未提供该能力时，结果为 `UNAVAILABLE`，这是预期的安全结果。任何实际 patch 应使用显式 `repair-apply -Force`，并保留 receipt 供回滚。

## 静态预检和依赖图

静态插件预检只读取指定目录中的 `.js`、`.mjs`、`.cjs` 文件，检查静态 `inject` 声明与 `ctx.*` 服务使用是否一致。它不会 import、require 或执行目标插件；动态 `ctx[...]`、动态 inject 以及超出文件/大小上限的输入会返回 `MANUAL_REVIEW`：

```powershell
.\Debug-DSH.ps1 -Action plugin-preflight `
  -InputPath .\path\to\plugin `
  -PreflightPath .\state\preflight.json
```

依赖图检查读取脱敏的 Profile/package metadata，输出 `nodes`、`edges`、`missing`、`cycles`、`unreferenced` 和 `protectedCore`。输入可以是 `manifest` 或 `profileManifest` 加 `packages` 的 JSON；也可以把 `-InputPath` 指向包含 `package.json` 和本地 `node_modules` 的测试 Profile 目录。它不调用 npm/pnpm，不联网，不安装依赖，也不执行 package code：

```powershell
.\Debug-DSH.ps1 -Action plugin-dependency-graph `
  -InputPath .\tools\fixtures\plugin-dependency-graph.json `
  -DependencyGraphPath .\state\dependency-graph.json

.\tools\Test-DSHDependencyGraph.ps1
```

缺失依赖、依赖环或未引用本地包会返回 `FAIL` 和非零退出码；`@deepseek-ai/*` 与 runtime 条目只会被标记为受保护节点，不会被当作可隔离插件。报告仍然只含包名、关系和版本规格类型，不回显绝对路径、源码、命令或凭据。

Trace loop 分析用于发现同一状态在短窗口内反复出现的情况。它只比较允许的状态/插件/Module 元数据，发现 `message`、路径、命令或凭据等字段时返回 `MANUAL_REVIEW`，不会把重复现象直接解释为根因：

```powershell
.\Debug-DSH.ps1 -Action trace-loop `
  -InputPath .\tools\fixtures\trace-loop.json `
  -WindowSize 12 `
  -RepeatThreshold 3
```

Trace 递归分析用于发现 Agent 或 Workflow 在生命周期事件中嵌套过深。它要求事件序号递增，并只接受明确的开始/结束标记；超过上限的输入直接 `FAIL`，未闭合、错配或动态标记进入 `MANUAL_REVIEW`。输出只保留计数、深度、序号和分类，不输出 Agent ID、Session ID、消息、路径或 Tool 参数：

```powershell
.\Debug-DSH.ps1 -Action trace-recursion `
  -InputPath .\tools\fixtures\trace-recursion.json `
  -MaxDepth 3

.\tools\Test-DSHTraceRecursion.ps1
```

任务守护（Guardian）是运行时的 observer-only 保护层。它监听 Host 的 `agent/created`、`agent/status` 和 `session/event`（若 Host 提供），用脱敏的 Tool 参数形状生成指纹，识别短窗口重复调用、子任务/工作流递归和取消/失败中断。默认配置为 `policy=auto`，在冷却时间内最多对同一 Session 发一次指导；设置为 `policy=report` 时只记录不指导。状态接口如下：

```powershell
Invoke-RestMethod http://127.0.0.1:3081/api/dsh-plugin-debug/guardian/status
```

接口和 `$DSH_HOME/guardian/events.jsonl` 只包含有界计数、事件类别、深度和不可逆指纹，不返回原始 Session ID、Tool 参数、消息正文或凭据。内存中的最近事件窗口和单条事件元数据有界；事件文件当前按行追加、没有自动轮转，因此不保证整个文件大小有界。长期运行时请按自己的保留策略管理本地日志，不要把日志提交或上传。守护不会终止任务、杀进程、重启 Host、禁用插件或修改 Profile；`agents` 服务或这些事件在 Host 中缺失时，插件仍可启动并保持 `UNAVAILABLE`/空闲状态。

重启前可以通过统一入口读取守护状态。空闲时返回退出码 0 和 `SAFE_TO_RESTART`；存在活动 Session 或未完成操作时返回退出码 2 和 `BUSY_DO_NOT_RESTART`，脚本只给出建议，不会自行重启：

```powershell
.\Debug-DSH.ps1 -Action guardian-status -Profile debug -Port 3081
.\tools\Test-DSHGuardianStatus.ps1
```

## 测试

测试源码和脱敏 fixture 会随 GitHub 源码一起发布，便于别人复现实现和检查发布边界：

```powershell
Set-Location .
.\scripts\Verify-Publication.ps1

Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHPluginIntegration.ps1
.\tools\Test-DSHLauncherConflict.ps1
.\tools\Test-DSHCrashGuard.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1
.\tools\Test-DSHGuard.ps1
.\tools\Test-DSHPluginHealth.ps1
.\tools\Test-DSHPluginState.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHTraceProfile.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
.\tools\Test-DSHBisect.ps1
.\tools\Test-DSHPreflight.ps1
.\tools\Test-DSHDependencyGraph.ps1
.\tools\Test-DSHTraceLoop.ps1
.\tools\Test-DSHTraceRecursion.ps1
.\tools\Test-DSHGuardianStatus.ps1
.\tools\Test-DSHPointerBrowser.ps1  # 可选；退出码 2 表示浏览器运行时不可用
Pop-Location
```

发布边界检查必须在 `npm ci` 之前运行；它会严格拒绝安装后生成的
`tools/runtime/node_modules`。runtime 安装属于本地/CI 测试准备，不属于 GitHub
源码或 npm 发布内容。

`tools\\fixtures` 中的 JSON/HTML 是合成且脱敏的输入数据，会被 trace 和浏览器契约测试直接引用。Crash Guard、启动冲突和 runtime supervisor 的 fake DSH 会在测试运行时创建到临时目录，测试结束后清理；仓库中没有真实 Profile、日志、凭据或崩溃转储。

`Test-DSHPointerBrowser.ps1` 需要 `python.exe`、`npx` 和可用的 Playwright 浏览器 daemon；缺少这些依赖时只报告 `UNAVAILABLE`，不会把静态 HTML 加载冒充成真实 DSH Web 验证。

Crash Guard 的测试还会检查启动处置回执：第一次启动失败、生成可逆隔离并受控重启后，回执必须变成 `recovered`，并保留被隔离插件 ID。这样别人不只可以看到“启动成功”，还可以审阅启动异常是如何被处理的。

插件二分计划也提供独立的可复现命令：

```powershell
.\Debug-DSH.ps1 -Action plugin-bisect-plan `
  -InputPath '.\tools\fixtures\plugin-bisect-plan.json' `
  -BisectPath '.\tmp\plugin-bisect-report.json'

# 比较两次脱敏诊断报告；重复 -InputPath 表示 before 和 after
.\Debug-DSH.ps1 -Action diagnostics-diff `
  -InputPath '.\state\before-incident.json' `
  -InputPath '.\state\after-incident.json' `
  -DiffPath '.\state\incident-diff.json'
.\tools\Test-DSHBisect.ps1
.\tools\Test-DSHDiagnosticsDiff.ps1
```

输入必须是脱敏 JSON，包含 `inventory`、失败证据和当前 Profile manifest。输出只保留插件 ID、证据类型、映射方式、`safe`/`protected`/`ambiguous` 分类、人工步骤和隐私契约；`safe` 只代表可以安全地列入人工试验顺序，不代表已经证明根因。

`npm pack --dry-run --ignore-scripts` 只验证可发布包。GitHub 源码可以包含测试脚本和测试输入，但 npm/DSH 包不应包含 `node_modules`、state、logs、`.env`、凭据或任何本机运行生成物。

## 更新功能和发布新版本

1. 在 `src` 或 `tools` 修改源码，同时新增或更新对应的 Node/PowerShell 回归测试。
2. 运行 `npm run check`，它会重新构建 `lib`、更新 `bundle-manifest.json` 并运行 Node 测试。
3. 运行 `Test-DSHStandalone.ps1`、启动冲突夹具和发布验证器。
4. 检查 `npm pack --dry-run --json --ignore-scripts` 的文件数，并同步 `SOURCE-SNAPSHOT.md`、`RELEASE-MANIFEST.json` 和必要的文档。
5. 修改 `package.json` 的 `version`，同步 `package-lock.json`，确认 CHANGELOG/README 描述与行为一致。
6. 先在本地做一次可审阅的 commit，再配置明确的 GitHub remote；新仓库第一次发布前应从 fresh clone 重跑测试。

发布前候选状态、GitHub remote、fresh clone 验证结果会记录在仓库根目录的
`RELEASE-MANIFEST.json` 和 `SOURCE-SNAPSHOT.md`；本地测试通过不等于真实 DSH
生产实例已经验证。

## 研究和吸收边界

本项目参考了公开的 `dsh-doctor`、`dsh-fail-logger`、`dsh-sentinel`、`dsh-turn-rewind`、`dsh-checkpoint-rewind` 和 `dsh-clawrouter` 等项目的公开 README/代码结构，但没有复制它们的源码，也不把它们加入运行时依赖。当前吸收的是可验证的设计形状：只读 doctor、失败去重、可逆 snapshot、执行前安全闸门和 bounded restart。

尚未默认加入的能力包括：常驻文件/HTTP watcher、模型二次审查危险命令、真正的 durable rewind、自动安装依赖和任意进程清理。这些功能会扩大权限或运行时边界，必须先有 DSH 官方 API、明确的安全策略和独立回归测试。

## 发布边界

仓库只公开 `packages/dsh-plugin-debug` 一个运行时包。插件商店目录和能力已经删除。测试程序属于源码仓库的一部分，但测试生成的临时目录、真实 DSH 状态、日志、Session、凭据和本机缓存永远不应上传。

## 许可证

MIT
