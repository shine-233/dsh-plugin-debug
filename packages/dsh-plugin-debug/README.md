# dsh-plugin-debug

This package is the single, foolproof DSH Debug Plugin. Its public product name
is `dsh-plugin-debug`; Profiles that still reference an older provenance ID need
an explicit migration or reinstall before this bundle is loaded.
All detection, diagnostics, recovery, trace and Crash Guard source lives in this
one package. Plugin-store capability is not part of the product.

## Upstream comparison and safety boundary

GitHub research confirmed that [jorinyang/dsh-doctor](https://github.com/jorinyang/dsh-doctor)
is a separate MIT-licensed DSH plugin with a structured doctor, repair scopes,
persisted LIFO journal, Cordis service, and standalone CLI. This project
absorbs the useful shape, but intentionally does not copy its broad `deps` or
`full` repair actions: no automatic `pnpm install`, profile initialization,
arbitrary process termination, or shell-built profile command is allowed here.

The local self-repair boundary is narrower and evidence-bound. Automatic
recovery can quarantine only an observed safe third-party plugin by changing
the tool's own `guard-state.json` and `guard.patch.yml`; it records pre/post
hashes, refuses rollback conflicts, requires explicit approval, and reports
`repaired-restart-required` until a requested restart and Web readiness check
actually succeed. A model can propose a validated JSON plan only when the Host
explicitly exposes a no-tools planner capability; it never receives execution
authority or changes workspace/Profile manifests/permission defaults.

The browser report is metadata-only. Pointer node descriptions contain only
structural tag/role data, never visible button or page text. Pointer ancestry
reports `sourceSearchIncomplete` when its bounded search cannot reach the root.
Tool Call observations include totals and machine-readable truncation flags, so
an 80-item sample cannot be mistaken for a complete history.

这是一个独立的 DeepSeek Harness（DSH）故障诊断与恢复套件。它把“鼠标指向页面元素显示来源”和启动、恢复、插件隔离、Tool Call 诊断等能力放在同一个发行目录中。

这里的“独立”指：运行时只需要 DSH 宿主、Node.js 与 Windows PowerShell，不依赖插件市场或其他社区插件；Crash Guard 和一键启动器在 DSH 进程外运行，这是为了让插件自身崩溃时仍然有进程可以隔离它。

## 已吸收的能力

| 能力 | 现在由本项目提供的部分 | 证据/边界 |
| --- | --- | --- |
| 鼠标来源标注 | Web Client 读取 `data-dsh-plugin`、`data-dsh-module`、CSS、Slot，并显示插件、Module、Slot、证据等级 | 没有标记的 DOM 显示“未知”，不会猜测来源 |
| 页面诊断 | CSS 冲突线索、重复 Module ownership、Slot 线索、浏览器 error/unhandledrejection 脱敏报告 | 线索不是因果证明 |
| 对话分支 | `session-history` 和 `session-fork` 观察/创建追加式分支 | 当前 rc.6 没有把原 Session 原地删除或重写；原 Session 保留 |
| Profile 恢复 | 配置文件 SHA-256 快照、恢复前 rescue snapshot、可逆恢复 | `.env` 只记录敏感元数据，不输出内容 |
| 工作区恢复 | 外置快照、相对路径与 SHA-256、恢复后校验 | 不删除快照之后新建的文件；不跟随 junction/symlink |
| 插件启停 | 只操作当前 Profile 的安全第三方依赖；quarantine 后重新启用需要显式确认 | 核心 `@deepseek-ai/*` 和 runtime `include:` ID 不自动操作 |
| 插件健康检查 | 清单、patch、bundle 解析、重复 patch、构建钩子、runtime failed plugin/duplicate module | API 不可用时仍可完成静态检查 |
| 崩溃隔离 | 外部守护进程根据启动日志与 inventory 候选生成可逆 `disabled: true` patch，并只恢复一次 | 是安全候选归因，不是数学因果证明；无法归因时不乱禁用 |
| 模型辅助自修复 | 由确定性诊断生成 advisory plan；只有 Host 明确提供无工具规划 Session 时才允许 DSH 模型提出 allowlist JSON | 默认 `UNAVAILABLE`/不修改状态；拒绝用户已有 Session、工作目录、执行事件、未知字段、未观察候选和过期证据；不会自动改权限或核心包 |
| 一键启动 | `Start-DSH-Debug.vbs` 后台启动，等待 DSH Web readiness 后再打开浏览器 | 默认只监听 loopback；端口被其他服务占用时不强行覆盖 |
| Tool Call 诊断 | 读取 session history 的 tool/call、tool/result、turn/end、dispatch error、模型上下文和权限字段元数据 | 观察到 `danger-full-access` 不等于获批、执行成功或知道模型原因；默认不导出参数正文和结果正文 |
| 运行时资源压力 | 在 diagnostics/incident 中记录 Node/PowerShell 进程数量、Node 工作集、物理内存比例和有限的 top PID，并将 warning/critical 降级为 `PARTIAL`/`degraded` | 不读取命令行、路径、环境变量或会话内容；不自动杀进程；资源压力不是插件故障的因果证明 |
| 脱敏 Trace/Eval | 将 session history 归一化为 metadata-only trace，并用 JSON case 断言 Tool Call、权限枚举、错误计数和事件顺序 | 不保留命令、参数值、结果正文、凭据、Cookie、Authorization 或完整 cwd；live 模式只读取一个有界 history 页面 |
| Trace baseline 门禁 | 比较两份脱敏 trace，错误增加时 `FAIL`，路线/工具/权限变化时 `WARN`，可用严格模式收紧 | 是回归信号，不是跨任务的结果等价证明；需要同类 baseline 才有意义 |
| 跨层事故包 | 将 Host、Profile、Guard、插件健康、Session 健康、上下文、安全、鼠标契约和可选 Session Trace 汇总到一个带组件哈希的 JSON | 只读采集和写本地报告分开标记；最终结果为 `COMPLETE`/`PARTIAL`/`UNAVAILABLE`/`FAIL`，不伪造运行时成功 |
| Tool Policy 闸门 | 基于 DSH rc.6 已存在的 `tools/pre-execute` 接缝，按工具名/JSON Pointer 规则返回 `allow`、`ask` 或 `deny` | 默认关闭；开启后也不改写参数、不执行 Tool、不替代 DSH 原生 sandbox/approval |
| 失败归档 | `dsh-fail-logger` 方向的本地去重计数，保存脱敏样本与哈希 | 不保存原始日志、Tool 参数或 Tool Result |
| 会话健康 | JSONL-like 会话的空文件、合法帧、损坏帧、torn tail 检查；识别 zstd 但不假装已解码 | zstd 显示 `not-decoded`，不把“未解码”报成损坏 |
| 上下文审计 | 指令/技能/清单文件的大小、近似 token 成本、重复内容与同名文件线索 | token 数是 UTF-8 bytes/4 的估算，不是模型 tokenizer 结果 |
| 本机安全审计 | Profile 本地依赖来源、patch 网络字符串、`.env` 存在性、Node listener 风险的只读脱敏报告 | 不读取 `.env` 内容，不代表完整的系统安全证明 |

这些功能是本项目自己的实现；上表中的社区项目只作为需求和兼容性参考，不会成为安装前置依赖，也没有把它们的包加入 `package.json`。

## 目录结构

```text
src/                         Web Client 来源标注实现
cordis.patch.yml             DSH 原生插件 patch
lib/                         构建后的 DSH bundle
DSH-Provenance.ps1           统一调度入口（Provenance 是兼容名称）
Start-DSH-Debug.*             Debug 一键启动入口（PowerShell/CMD/VBS）
Start-DSH-Combined.*          Debug + 可选 Agent overlay 入口
tools/                       同包的 Host-side 工具与外部守护逻辑
  DSH-Guard.psm1             Crash Guard 与插件 ID 安全映射
  DSH-Repair.psm1            受限 repair plan、模型响应校验、receipt/回滚
  DSH-Recovery.psm1          Profile/工作区快照恢复
  DSH-Workbench.ps1          启动、诊断、快照、启停、Session 操作
  DSH-ProvenanceSuite.ps1   context/security/session/failure/provenance 五类诊断
  DSH-SelfRepair.ps1         repair-plan/assist/apply/revert 入口
  DSH-Trace.psm1             metadata-only session trace 归一化与断言
  DSH-ResourcePressure.psm1  只读 Node/PowerShell 资源压力观测
  DSH-TraceEval.ps1          trace contract/eval/live 入口
  Test-DSHCrashGuard.ps1     临时 fake runtime 的 Crash Guard 启动集成测试
  Test-DSHResourcePressure.ps1  资源压力三态与隐私回归测试
  Test-DSHIncidentRuntimeEvidence.ps1  事故包资源证据跨层回归测试
  DSH-Incident.ps1           跨层脱敏事故包与组件完整性哈希
  fixtures/                  脱敏 Tool Call trace 与回归 case
  (temporary fixtures are generated by tests and removed after each run)
  runtime/package.json       固定的 DSH rc.6 安装清单，不含 node_modules
tool-policy.patch.example.yml  可选的 Tool Policy 配置样例
```

## 安装与一键启动

直接双击下面的入口即可。启动器第一次运行时会把本仓库的 bundle 以 `--offline` 方式装入 `debug` Profile；它只安装本地 Debug bundle：

```text
Start-DSH-Debug.vbs
```

或在 PowerShell 中观察输出：

```powershell
.\Start-DSH-Debug.ps1 -NoBrowser
```

默认启动 `debug` Profile、`127.0.0.1:3081`，并开启一次性 Crash Guard。它会自动安装本工具自己的 `dsh-plugin-debug` bundle，但不会自动搜索、安装或调用任何插件市场。

需要同时加载可选 Kimi/Codex Agent overlay 时，先显式运行
`tools\Install-DSH-Agents.vbs`，再使用 `Start-DSH-Combined.vbs`。Agent overlay
不是 Debug runtime 依赖，不会默认安装，也不会把凭据写入源码。

如果使用已经安装好的 DSH CLI，也可以直接把这个单一插件加入指定
Profile，然后重启 Web：

```powershell
dsh plugin --profile debug add . --offline
```

如果 Profile 已经由其他方式安装好 bundle，启动器会复用它；如果你明确不希望启动器修改 Profile，可以传 `-NoPluginInstall`。此模式允许宿主启动，但当前实例不会提供鼠标来源面板，适合调试宿主或运行 Crash Guard fixture。

### 启动保护、页面通知与诊断会话

启动器在 Web ready 前后都会检查插件 inventory。若失败条目能由当前
Profile manifest 明确映射为安全的第三方插件，它会写入可逆的 Guard patch，
最多重启一次，并用 `dsh_debug_guard=isolated` 标记打开的页面。页面会显示
启动保护通知和“打开诊断”入口；不会把日志、Tool 参数、凭据或本机路径放进
URL。

页面只会在 Host 同时声明 `diagnosticSessionPolicy.automatic=true` 和
`mode=no-tools` 时自动创建隔离诊断 Session，并用脱敏的元数据提示它只做
人工复核建议。普通 rc.6 Host 没有这个能力时会显示“未创建”，不会创建一个
可能执行命令的普通 Session。重复故障按页面、故障类型和插件名称去重。

Kimi/Codex overlay 是可选的外部 Provider 集成，不是插件市场，也不属于本包的运行时依赖。需要时显式安装到同一个 Profile，再启动 Combined 入口：

```powershell
.\tools\Install-DSH-Agents.ps1 -Profile debug -ShowWindow
.\Start-DSH-Combined.ps1 -Profile debug -NoBrowser
```

安装器使用 pnpm 从包源安装 DSH 官方 Provider 包，并只把本地 overlay 作为 patch 传给 DSH；Provider 的实现、外部 CLI 和凭据仍由宿主环境管理。

## 功能更新与发版

修改功能时只改 `src/`、`tools/`、入口脚本和测试；不要手工编辑 `lib/` 或
`bundle-manifest.json`。在包目录执行构建和回归测试：

```powershell
npm test
npm run check
npm run check:standalone
npm run check:integration
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-DSHLauncherConflict.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-DSHTraceProfile.ps1
```

需要发布不兼容变更时，先按 SemVer 更新 `package.json` 和
`package-lock.json`，然后再次运行 `npm run check`；构建脚本会重新生成
`lib/` 与 bundle 清单。版本号、入口、依赖或 patch 改动后，还要从包目录运行
`npm pack --dry-run --json --ignore-scripts`，把输出的 `entryCount` 同步到仓库根目录
的 `RELEASE-MANIFEST.json` 与 `SOURCE-SNAPSHOT.md`，再运行：

```powershell
Set-Location ..\..
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\Verify-Publication.ps1
git diff --check
```

`npm pack` 只证明将要进入安装包的文件边界；GitHub 源码还应包含测试脚本、
脱敏 `tools/fixtures` 和 CI 配置。测试期间生成的 fake DSH、临时 Profile、日志
和状态文件不上传。首次发版前先审阅 `PUBLICATION-CHECKLIST.md`，确认仓库名称、
所有者、版权人和 remote 后再提交或 push；本地测试通过不等于真实 DSH 或 GitHub
运行验证通过。

`Test-DSHPointerBrowser.ps1` needs `python.exe`, `npx`, and a usable Playwright
browser daemon. Missing browser dependencies are reported as `UNAVAILABLE`, not
as proof of a real DSH Web verification.

## 统一入口示例

```powershell
# 启动并等待 Web readiness
.\Debug-DSH.ps1 -Action start

# 当前运行实例的 Host/Session/Tool Call 元数据诊断
.\Debug-DSH.ps1 -Action diagnostics -Profile debug -Port 3081 -ExpectedModel 'gpt-5.6-sol'

# Profile 静态插件健康检查，不访问 API
.\Debug-DSH.ps1 -Action plugin-health -Profile debug -SkipApi

# 工作区快照与恢复；恢复必须显式 -Force
.\Debug-DSH.ps1 -Action workspace-snapshot -Workspace 'C:\work\demo' -SnapshotRoot 'C:\work-snapshots'
.\Debug-DSH.ps1 -Action workspace-restore -Workspace 'C:\work\demo' -SnapshotRoot 'C:\work-snapshots' -SnapshotId '<id>' -Force

# 参考当前 Session 创建安全分支，而不是改写原 Session
.\Debug-DSH.ps1 -Action session-history -Profile debug -Port 3081 -SessionId '<session-id>'
.\Debug-DSH.ps1 -Action session-fork -Profile debug -Port 3081 -SessionId '<session-id>' -AtSeq 12

# 将插件写入可逆的 Profile patch；quarantine 插件重新启用要显式清除状态
.\Debug-DSH.ps1 -Action plugin-disable -Profile debug -PluginId '<profile-dependency-id>'
.\Debug-DSH.ps1 -Action plugin-enable -Profile debug -PluginId '<profile-dependency-id>' -ClearQuarantine

# 内化的社区能力方向
.\Debug-DSH.ps1 -Action context-doctor -Root 'C:\work\demo' -IncludeUserConfig
.\Debug-DSH.ps1 -Action security-audit -Profile debug
.\Debug-DSH.ps1 -Action session-health -Profile debug
.\Debug-DSH.ps1 -Action fail-log -InputPath 'C:\temp\sanitized-failure.log' -StateRoot 'C:\temp\dsh-failure-state'

# 检查内置鼠标溯源浏览器桥接契约，以及它是否已进入当前 Profile（只读，不连接网络）
.\Debug-DSH.ps1 -Action provenance

# 检查脱敏 Trace contract，并运行本地 Tool Call 回归 case
.\Debug-DSH.ps1 -Action trace-contract -InputPath '.\tools\fixtures\tool-call-trace.json'
.\Debug-DSH.ps1 -Action trace-eval -InputPath '.\tools\fixtures\tool-call-trace.json' -CasePath '.\tools\fixtures\tool-call-case.json'

# 比较当前 trace 与成功 baseline；错误增加时退出码为 1
.\Debug-DSH.ps1 -Action trace-baseline `
  -InputPath '.\tools\fixtures\tool-call-trace.json' `
  -BaselinePath '.\tools\fixtures\tool-call-baseline.json'

# 在完全临时的 Profile/Runtime 中验证“崩溃 -> 隔离 -> 重启 -> Web ready”
.\Debug-DSH.ps1 -Action crash-fixture

# 汇总当前可观察层；只写本地报告，不创建 Session、不发送 prompt
.\Debug-DSH.ps1 -Action incident-capture `
  -Profile debug -Port 3081 `
  -Workspace 'C:\work\demo' `
  -IncidentPath '.\state\incident-report.json'

# 提供 SessionId 后，事故包会额外读取一页 metadata-only session.history
.\Debug-DSH.ps1 -Action incident-capture `
  -Profile debug -Port 3081 -SessionId '<session-id>' `
  -IncidentPath '.\state\incident-with-trace.json'

# 对一个真实 Session 做一次有界、只读的 metadata-only 观察
.\Debug-DSH.ps1 -Action trace-live -Profile debug -Port 3081 -SessionId '<session-id>' -CasePath '.\tools\fixtures\tool-call-case.json'

# 从诊断生成只读 repair plan；不会修改 DSH、Profile 或工作区
.\Debug-DSH.ps1 -Action repair-plan -Profile debug -Port 3081 -PlanPath '.\repair-plan.json'

# 让 DSH 自己的 minimal Session 只返回受限 JSON 建议；默认仍不应用
.\Debug-DSH.ps1 -Action repair-assist -Profile debug -Port 3081 -PlanPath '.\model-repair-plan.json'

# 人工审查 JSON 后，才允许写入可逆 Guard patch；完成后需重启 DSH 才会加载
.\Debug-DSH.ps1 -Action repair-apply -Profile debug -DshHome 'C:\path\to\.dsh' -StateRoot '.\state' -PlanPath '.\model-repair-plan.json' -Force

# 仅恢复该 receipt 捕获的 guard-state.json / guard.patch.yml
.\Debug-DSH.ps1 -Action repair-revert -ReceiptPath '.\state\repair\<id>\manifest.json' -Force

# 导出脱敏的最小复现目录；输入只允许 JSON，多个路径可作为 PowerShell 数组传入
.\Debug-DSH.ps1 -Action repro-export `
  -InputPath @('.\state\incident.json', '.\state\diagnostics.json', '.\state\trace.json') `
  -ReproPath '.\state\repro-incident' -ReproZip
```

`provenance` 会检查已构建的 Client 是否包含鼠标溯源桥接。普通页面会尽力暴露
`window.__DSH_PLUGIN_PROVENANCE__`，而 DSH 的冻结浏览器运行时使用
`meta[data-dsh-provenance-bridge="1"]` 和 `dsh-plugin-debug:pointer` 事件作为兼容通道。
桥接提供 `enable/disable/setEnabled`、当前指针来源、单节点 `inspect`、整页 `scan` 和脱敏错误读取接口。
这个 Host 命令只检查契约；真正的插件、Module、Slot 归属仍必须在 3081 Web 页面里移动鼠标验证。
它不会读取 Cookie/Token，不截屏，不发送网络 payload，也不读取 Tool 参数正文。

### 脱敏 Trace 与 Eval

`trace-contract` 和 `trace-eval` 使用本地 JSON fixture，不需要启动模型。`trace-live` 才会调用 DSH 的 `session.history`，只读取指定 Session 的一页事件，默认上限为 500 条；它不会创建 Session、发送 prompt 或执行 Tool。

Trace schema v1 只保留事件类型、序号、turn/step、工具名、参数键名是否出现、受限的 sandbox permission 枚举、model/provider 路由和错误布尔值。参数值、命令正文、Tool Result 正文、凭据、Cookie、Authorization、完整 cwd 都会被省略。Eval case 只能断言 `equals`、`contains`、`atLeast` 和 `eventSequence`，不能把命令或路径塞进断言文件。

内置 fixture 专门覆盖“`bash` 携带 `danger-full-access`，随后 Tool Result 失败”的可观察链路。它证明的是诊断器能正确记录和回归元数据，不证明某个模型、sandbox 或 DSH 版本的根因已经被修复。

`trace-baseline` 使用同一 metadata-only schema 做回归门禁：`errorResultCount`、`dispatchErrorCount`、`turnErrorCount` 或 `pendingCount` 增加会失败；模型路由、工具集合或权限枚举变化会给出 warning。它不能把不同任务的 trace 当作可直接比较的性能结论。

`crash-fixture` 不连接真实 DSH，也不改动真实 `DSH_HOME`。它复制启动器和 Guard 到临时目录，使用本机 Node 启动一个故意第一次崩溃的 fake runtime，验证 quarantine patch 和第二次 Web readiness，然后删除临时进程和文件。

`incident-capture` 是跨层证据入口。它会把模型/provider、插件数量/失败数、默认 sandbox/approval、Profile manifest 摘要、Guard quarantine、插件健康、Session 帧健康、上下文 token 估算、安全审计、鼠标 bridge 契约和可选的 metadata-only Trace 放入同一 JSON，并为每个组件计算 SHA-256。端口不可用时组件会显示 `UNAVAILABLE`，不会把“报告成功写出”误报成“DSH 修复成功”。

diagnostics/incident 还会先采样本机 Node/PowerShell 进程压力。Node 进程数量或其工作集超过阈值时，运行时证据会标记为 `degraded`，整体诊断通常为 `PARTIAL`；这用于解释 OOM、启动超时和 Web 假死等环境性症状，不会自动停止任何进程，也不会把资源压力直接归因于某个插件。

### 模型辅助自修复的安全边界

The incident component status is more precise than a single port check:
static and Host evidence with an unavailable loopback or requested Session is
`PARTIAL`; `UNAVAILABLE` means that component returned no usable report.

`repair-plan` 是确定性的 dry-run；`repair-assist` 只有在 `host.describe` 明确声明 Host-side no-tools planner 能力时才会创建临时、隔离的 minimal Session。当前 rc.6 的 `session.create` schema 没有独立的 no-tools 参数，因此普通 DSH Host 会直接返回 `UNAVAILABLE`，不会创建一个可能带工具的 Session。即使未来 Host 提供该能力，工具仍会轮询历史：一旦观察到 `tool/*`、审批或执行类事件，就立即丢弃整份建议。

允许的操作只有 `quarantine-plugin`、`restart-profile` 和不修改状态的 `recommendation`。计划 schema v2 必须绑定 `incidentId`、证据 `evidenceHash`、精确 Profile、已观察的候选 ID 和 `expiresAt`；模型输出会经过本地 schema 和插件 ID 白名单校验，未知顶层/操作字段、重复候选、错误 Profile、过期计划以及 `requiresApproval=false` 都会被拒绝。`command`、`script`、`shell`、`args`、`arguments`、`path`、`url`、`cwd`、`expression`、`eval`、`code` 等字段也会被拒绝。即使计划合法，也必须显式传 `-Force` 才能执行；每次应用会保存带 post-image hash 的 receipt，当前文件已被改动时 `repair-revert` 会返回 `ROLLBACK_CONFLICT`，不会覆盖用户改动。它不会替你修改 `danger-full-access`、核心 `@deepseek-ai/*` 包、Profile manifest 或工作区文件，也不会自动重启正在运行的 DSH。

### 可选的 Tool Policy

本机 rc.6 的 `@deepseek-ai/dsh-tools` 已观察到 `tools/pre-execute`，所以本项目把权限闸门实现内置进自己的 Host bundle；它不是另一个 `dsh-tool-policy` 依赖。默认配置是关闭的，避免仅仅安装来源标注插件就改变现有 Tool 行为。

确认规则后，才把 [tool-policy.patch.example.yml](tool-policy.patch.example.yml) 的条目合并到目标 Profile 的 `cordis.patch.yml`。启用后：

- `bash`、`pwsh`、`shell`、`terminal*`、`run_code` 携带 `danger-full-access` 时默认返回 `ask`；
- `mcp_*` 可以按样例强制 `ask`；
- `deny` 只能阻止调用；`ask` 交给 DSH 原生审批接缝；
- 不重写参数，不把参数正文写入日志，不把“字段出现”解释为“执行成功”；
- sandbox 仍然是能力隔离层，Tool Policy 只是逐调用决策层，二者不能互相替代。

## 安全与兼容性边界

- `include:<id>` 是 runtime inventory 的 ID；Profile patch 要使用清单里的依赖 ID，不能把 `include:` 原样写入 patch。
- Crash Guard 只在日志和当前 Profile 清单能形成安全候选时隔离插件。普通端口连接失败、没有错误日志或候选不唯一时不会随便禁用插件。
- 一键启动器的 Crash Guard 在 Host 进程外读取启动日志和插件 inventory；达到阈值后只为安全第三方候选写可逆 Guard state/patch，并最多按本次启动流程恢复一次。它不会因为 Web 端口慢、普通 API 失败或鼠标溯源页面未加载就禁用插件。
- Client 来源标注和 Host-side Guard 是两个层次。Web Client 不能可靠地捕获 Host 进程启动前的异常，也不拥有文件恢复和插件禁用权限。
- `session-fork` 是追加式安全分支；它不是删除原 Session、撤回历史，也不能撤销网络请求、数据库写入或已经执行的外部命令。
- 工作区恢复只覆盖快照中捕获的文件，恢复前默认创建 rescue snapshot；后来新增文件保留。
- 诊断报告不输出 Cookie、Authorization、API key、`.env` 内容、完整 Tool 参数、Tool Result 正文或完整工作目录。
- 资源压力报告只保留进程名、PID、启动时间、工作集、数量和内存比例，不保存命令行、路径、环境变量或会话正文。
- `gpt-5.6-sol` 只有在 session history/request context 里观察到才算运行时证据。当前实例如果报告的是另一个 model，不能改写成 `gpt-5.6-sol`。
- `repair-assist` 生成的是受限修复建议，不是“模型已经修复成功”的证明；实际是否恢复，要看 `repair-apply` 的 receipt、下一次 DSH 启动和后续 diagnostics。
- 本目录的 `runtime/package.json` 只固定 DSH `0.1.0-rc.6`。首次启动安装的是 DSH 核心，不是社区插件；如果你已经有可用 DSH runtime，可以使用 `-NoInstall`。

## 验证

```powershell
Push-Location .
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
.\tools\Test-DSHGuard.ps1
.\tools\Test-DSHPluginHealth.ps1
.\tools\Test-DSHPluginState.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHPointerBrowser.ps1  # optional; exit 2 means browser runtime unavailable
Pop-Location
```

`npm run check` 验证 Web bundle 与 Client 回归测试；`Test-DSHStandalone.ps1` 只使用临时目录验证 PowerShell 解析、独立启动器没有 plugin-store/second-package 耦合、上下文审计、安全审计、会话帧分类、失败聚合、鼠标溯源桥接契约、脱敏 Trace/Eval/baseline、跨层 incident capture、Profile/Workspace snapshot restore、插件启停、repair plan 的生成、受限应用、receipt 回滚、恶意字段拒绝、Crash Guard 单候选隔离、真实启动器重启和空 `AtSeq` 回归。它不会停止现有 DSH 实例，也不会修改真实用户 Profile。

## 社区方案的关系

社区已经有 Rewind/Undo、插件市场、失败记录、会话健康和元素标注等不同方向的项目；具体核对记录见 [RESEARCH.md](RESEARCH.md)。它们不是 DeepSeek 官方全部能力的同一个发行包。这个仓库选择“吸收行为和测试思路，重新实现为一个独立包”的路线。以后如果直接复制某个社区项目的代码，必须保留对应许可证与版权声明；当前这版不把这些社区包写进运行时依赖。

## Result contract

The Host diagnostics use a shared result vocabulary. `PASS` means the
requested evidence was collected without an observed problem. `PARTIAL` means
some evidence was collected but a loopback API, requested Session, or other
optional source was unavailable. `FAIL` means the report contains a concrete
health error, such as a missing declared bundle or a corrupted manifest.
`UNAVAILABLE` is reserved for a component that produced no usable report at
all. Incident capture preserves these distinctions when it counts component
statuses; writing a local JSON report is never treated as proof that DSH was
recovered.

## Minimal repro export

`repro-export` absorbs the most useful part of the community doctor pattern:
make the evidence portable without making the raw incident portable. It accepts
incident, diagnostics, metadata-only trace, pointer, plugin-health, and repair
receipt JSON files and writes a fixed three-file artifact set: `repro.json`,
`manifest.json`, and `README.txt`. `-ReproZip` additionally creates a sibling
zip containing those three files.

The exporter is offline and fail-closed. Its allowlist keeps plugin/module/slot
IDs, Tool Call names and sequence metadata, status/error code/type summaries,
permission enums, component hashes, and bounded timestamps. It drops Tool
arguments and results, session/workspace text, `.env`, cookies, tokens,
authorization values, URLs, commands, scripts, and absolute paths. It rejects
malformed JSON, oversized inputs, reparse-point inputs, and an output directory
that contains an input file. It never modifies the source evidence.

## Runtime root and Session discovery

When the diagnostic scripts are used outside the bundled launcher, pass the
launcher runtime explicitly so static bundle checks use the same DSH runtime:

```powershell
$runtimeRoot = if ($env:DSH_RUNTIME_ROOT) { $env:DSH_RUNTIME_ROOT } else { '.\tools\runtime' }
.\Debug-DSH.ps1 -Action plugin-health -Profile debug `
  -RuntimeRoot $runtimeRoot -SkipApi
.\Debug-DSH.ps1 -Action diagnostics -Profile debug -Port 3081 `
  -RuntimeRoot $runtimeRoot
```

The health report records the runtime roots it checked. Default `session-health`
discovery is limited to DSH `sessions` directories and the `.jsonl`, `.ndjson`,
`.session`, and `.zst` extensions; it does not treat a Profile `package.json`
as a Session. An explicit `-InputPath` is retained for manual frame checks and
is labeled `explicit-file` in the report.

## Runtime supervisor and fixture boundary

The provenance start entry enables the host-side Supervisor by default. Use
`-NoSupervisor` for a short diagnostic process when a resident monitor is not
needed. The Supervisor only manages the DSH child recorded by this launcher,
keeps the pointer bundle independent from any plugin-store capability, and allows at
most one quarantine-and-restart cycle. A second failure becomes `degraded`;
it is not an infinite self-healing loop.

The disposable `runtime-supervisor-fixture` verifies the post-readiness failure
path, the reversible `disabled: true` patch, the second Web readiness gate, and
the final `healthy` state. It does not connect to the real `3081` instance or
modify the real `DSH_HOME`.

```powershell
.\Debug-DSH.ps1 -Action runtime-supervisor-fixture
```

## Trace autopsy and bounded known-good recovery

`trace-autopsy` is exposed by the same `DSH-Provenance.ps1` dispatcher. It
analyzes a metadata-only trace for retry storms, pending calls without a
result, registry mismatches, repeated permission errors, route changes,
timeouts, and high-risk calls after failure. Its finding evidence is limited
to `seq` and `callId`; raw commands, arguments, results, credentials, cookies,
authorization headers, and cwd are not returned.

```powershell
.\Debug-DSH.ps1 -Action trace-autopsy `
  -InputPath '.\tools\fixtures\tool-call-trace.json'
.\Debug-DSH.ps1 -Action trace-autopsy-fixture
.\Debug-DSH.ps1 -Action live-api-fixture
```

`known-good-save` captures only bounded Profile/Guard configuration files. It
does not capture or restore workspace files or `.env`. `known-good-restore`
checks current Profile hashes before writing, preserves any quarantine entries
observed after the checkpoint, optionally checks loopback Web readiness and
plugin inventory, and permits at most one automatic restore per checkpoint.
Conflicts or failed post-restore checks return `MANUAL_REVIEW` rather than
silently retrying.

```powershell
.\Debug-DSH.ps1 -Action known-good-save -Profile debug `
  -DshHome "$env:USERPROFILE\.dsh" -StateRoot '.\state\debug'
.\Debug-DSH.ps1 -Action known-good-list -Profile debug
.\Debug-DSH.ps1 -Action known-good-restore -Profile debug `
  -SnapshotId '<checkpoint-id>' -StateRoot '.\state\debug' -Force
.\Debug-DSH.ps1 -Action known-good-fixture
```

## Embedded pointer provenance distribution

The pointer inspector is part of this package's Client bundle; it is not a
second runtime plugin and it does not require any community plugin, `oh-dsh`, or
a community marketplace. `npm run check` generates `bundle-manifest.json`,
which records the embedded pointer bridge contract and SHA-256 hashes for the
four runtime artifacts. The Windows one-click launcher vendors that manifest
and refuses to reuse a same-name Profile installation when the bundle is old,
modified, or missing the embedded pointer contract.

Use `Start-DSH-Debug.vbs` from this package root to load the same embedded
pointer inspector. The visible overlay still reports
only evidence the page exposes: explicit plugin markers are high confidence,
CSS sources are medium confidence, Slot-only clues are low confidence, and an
unmarked DOM node remains unknown.

The browser diagnostics JSON now includes a bounded `pointer` observation with
`observationId`, `pageObservationId`, `observedAt`, plugin/module/Slot evidence,
and confidence. It does not include page text, screenshots, cookies, tokens, or
Tool Call bodies. Import that JSON into the Host-side diagnostic chain with:

```powershell
.\Debug-DSH.ps1 -Action pointer-evidence -InputPath '.\pointer-report.json'
.\Debug-DSH.ps1 -Action incident-capture -Profile debug `
  -PointerPath '.\pointer-report.json' -IncidentPath '.\state\incident.json'
```

The imported pointer source is an observation, not proof of causality. The
report deliberately returns `causalAttribution = not-supported` and requires
manual review when the evidence is CSS- or Slot-derived, ambiguous, or cannot
be matched to the plugin inventory and runtime error.

## License

MIT
