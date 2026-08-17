# DSH Debug Plugin（DSH 调试插件）

这是单包 `dsh-plugin-debug` 的完整中文手册。它把 DSH 检测、调试、来源追踪、日志取证、恢复、崩溃防护（Crash Guard）、插件预检、追踪（Trace）分析、任务守护和一键启动能力合并到一起；不依赖插件商店，也不会安装或调用 `dsh-plugin-store`。包内默认的 [`README.md`](README.md) 也是中文简版，GitHub 首页不会要求读者先阅读英文文档。

本手册说明当前源码能做什么、明确不会做什么，以及如何测试、更新和发布。版本是否已经推送，以仓库中的 [`RELEASE-MANIFEST.json`](../../RELEASE-MANIFEST.json)、[`SOURCE-SNAPSHOT.md`](../../SOURCE-SNAPSHOT.md) 和远端提交为准；本地测试通过不等于生产 DSH 已验证。这里使用相对链接，打开 tag/source archive 时会继续指向同一份快照，不会跳到另一个 `main` 提交。

公开证据记录中的 `0.8.4` 已完成 GitHub source release 的源码、CI、CodeQL 和 fresh-clone 证据闭环：source commit
`687dbaba3897a50ff2c797049ad9755eb76576d5` 的精确 fresh clone 通过 95/95 Node 测试、集成测试、61 文件 standalone 和发布边界验证，发布包为 108 个文件。本包不发布到 npm registry；真实有数据 Session、模型请求、第三方插件安装和跨平台兼容仍未证明；真实 Host/Web compatibility lane 仍需显式 opt-in，不能把 `UNAVAILABLE` 写成 `PASS`。`dsh_agent_report`、`plugin_check` 和 hotswap 能力仍按只读、脱敏、fail-closed 合同运行；正式状态以 [`RELEASE-MANIFEST.json`](../../RELEASE-MANIFEST.json) 和 GitHub 远端 ref 为准。

## 先看结论（普通用户版）

`dsh-plugin-debug` 是 DSH 的本地检查和故障诊断插件。它能检查插件仓库、查看 Host 的插件清单、记录启动故障、生成可逆的隔离回执，并在 Host 提供 Session 数据时生成看得懂的 Agent 报告。

它不能凭空修复 DSH，不能保证发现的失败插件就是根因，也不能把没有官方合同的插件热切换起来。它不会运行被检查的插件，不读取凭据，不上传报告，不执行 Session 里的命令，也不会把本地测试冒充成 GitHub 或生产验证。

这版已经吸收公开 [`dsh-whale-report`](https://github.com/SenmuuuuW/dsh-whale-report) 的安全确定性能力：用固定代码统计 Session、Token、费用估算、Tool Call、失败、重试和风险，再生成中文报告。报告不调用模型、不联网抓价格、不读取余额或密钥；上游不是本包的运行时依赖。

安装时先把本地 bundle 加入一个专用 Profile，再启动 DSH。想确保这次不自动联网，先准备好 pinned runtime，并使用 `-NoInstall`；省略它时，启动器可能按 lockfile 执行一次 `npm ci`，只用于准备 runtime，可能需要联网。

验证时要分清三件事：Web 能打开，只说明启动层通过；工具能调用，只说明注册和分发（dispatch）通过；报告有数据，才说明当前 Host 提供了可读的 Session 数据。任何一层没有证据，都不要向上扩大结论。

### 三个最重要的命令

1. 安装本地插件：

   ```powershell
   dsh plugin --profile debug add . --offline
   ```

   退出码为 `0` 表示本地 bundle 安装成功，不表示 DSH Web 已启动，也不表示已有历史 Session。

2. 启动并观察 Web：

   ```powershell
   .\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
   ```

   看到 Web ready 或 `supervisorStatus=healthy`，表示启动和插件清单达到健康状态；`degraded` 表示插件失败无法安全归因或恢复，不是“已经修好”。

3. 生成 Agent 报告：

   ```text
   dsh_agent_report(preset="weekly")
   ```

   `PASS` 表示查询成功；`0 Session` 表示查询成功但时间范围内确实没有会话；`UNAVAILABLE` 表示 Host 没有可读的 Session 数据源；`PARTIAL` 表示只读过程中有失败或触及上限。

### 为什么有时是 `UNAVAILABLE`，有时是 `0 Session`

`UNAVAILABLE` 不是“查到了零条历史”，而是 Host 没有提供 `sessionQuery`/当前会话服务，或者查询入口本身不可读。插件没有数据源时会停止，不会拿测试 fixture 或猜测内容冒充历史。

`0 Session` 的含义相反：查询服务已经成功回应，只是所选的 `daily`、`weekly` 或自定义时间范围内没有会话。隔离的新 Profile 通常没有历史，所以这是正常的空结果，不是报告失效。

如果 Host 只提供 `ctx.sessions`，报告会注明“仅当前内存会话”，不能当成完整历史。若部分 Session 或事件读取失败，或者达到读取上限，状态会是 `PARTIAL`，不能当成完整账单。

### `rm -rf` 到底是什么，插件会不会执行它

`rm -rf` 是 Unix/Linux shell 中常见的递归、强制删除写法；和路径拼在一起时可能造成很大破坏。它在本插件里只作为 Session 历史事件中的高风险文字模式被识别，报告只记录风险类别和计数，不执行、不回放，也不把原始命令写进报告。

因此，本插件可以避免“因为看见 `rm -rf` 就自己执行”的风险，但它不是命令拦截器，不能保证阻止另一个 Agent 或 Host 发出历史中的危险 Tool Call。要真正阻止执行，仍需要 DSH Host 的审批、沙箱或 Tool Policy；本插件不会假装已经拦截成功。

上游项目的 `rm -rf lib` 只是它自己的构建脚本，未被复制进 Debug 包。当前 Debug 构建使用 Node 文件 API；仓库里的 `rm -rf /` 只存在于合成测试数据和风险识别规则中，不会被当作命令运行。

### 真实 DSH rc.6 验证到哪里

截至 `2026-08-17`，在隔离的临时 Profile 中用 pinned `@deepseek-ai/dsh@0.1.0-rc.6` 验证到的范围包括：Web 返回 `HTTP 200`；`host.describe`、`session.list` 和 `pluginInventory/list` 可以调用；Host inventory 观察到 `dsh-plugin-debug` 为 active。本轮还用实际 shipped `web` Profile 跑通了 `Test-DSHCompatibility.ps1 -ConfirmRealDsh -StartPinnedRuntime`：134 条 inventory 中确认 Debug 插件为 active；这只是当前 dirty 工作树的启动/注册证据，不是发布 commit 或有数据 Session 证据。

还验证了三个工具都能通过真实 ToolRuntime 注册和调用：`plugin_check`、`plugin_hotswap_check`、`dsh_agent_report` 的 schema 均已注册，dispatch 均返回 `isError=false`。其中热切换检查仍给出 `UNAVAILABLE`，执行标记为 `NOT_ATTEMPTED`；这符合安全设计。

该隔离 Profile 没有真实历史 Session，因此 `dsh_agent_report` 只证明了“能调用并返回合法的空报告”：状态为 `PASS`、Session 数为 `0`。尚未证明有业务数据时的完整 Token、费用、风险和 Tool Call 统计，也不能写成“已经读取真实业务历史”。

同一 rc.6 验证中，直接调用 `session.create` 被外部运行时的 `agent-preset-invalid` 阻塞，原因是 `deployment:persona` 重复注册。这个错误不是 Debug 插件产生的；在修复官方 Host 合同前，不应通过修改真实 Profile 或凭据来绕过它。

建议环境：PowerShell 7（命令名 `pwsh`）、Node.js 22 或更高版本；CI 当前覆盖 Node 22/24 和 PowerShell 7 主流程。离线核心测试不需要真实 DSH；页面、浏览器和 Host API 测试需要额外的本机运行环境。PowerShell 5.1 只作为兼容性检查宿主；如果本机两者都装有，优先使用 `pwsh`。

### 质量、SBOM 与真实兼容性门禁

这是纯 JavaScript/PowerShell 包，因此 `typecheck` 没有 TypeScript 源码时会明确报告 `SKIPPED`，不会制造假绿；源码目录中可以运行：

```powershell
npm ci --ignore-scripts
npm run lint
npm run format:check
npm run typecheck
npm run coverage
npm run check:runtime-lock
npm run sbom:check
```

仓库提交了确定性生成的 `sbom/dsh-plugin-debug.spdx.json`（SPDX 2.3）和 `sbom/dsh-plugin-debug.cdx.json`（CycloneDX 1.5）。`npm run sbom:check` 会按插件和 pinned runtime 两份 lockfile 重新生成并比较，清单不包含当前时间或随机 UUID。安装 runtime 后再运行 `npm run check:runtime-lock:installed`，会逐项核对已安装树的版本；缺 lockfile、根依赖不一致或锁定版本漂移都会失败。

真实 DSH Host/Web 兼容性是手动且明确 opt-in 的额外门禁，不使用 `Test-DSHLiveApi.ps1` 的 fake fixture，不调用模型，不安装插件，也不执行热切换。先启动要验证的真实 DSH，再运行：

```powershell
pwsh -NoLogo -NoProfile -File .\tools\Test-DSHCompatibility.ps1 `
  -ConfirmRealDsh -BaseUrl http://127.0.0.1:3080
```

它会真实请求 Web 首页、`host.describe` 和 `pluginInventory/list`，并要求 Host inventory 中出现 `dsh-plugin-debug`。不传 `-ConfirmRealDsh` 会返回 `UNAVAILABLE`/退出码 `2`；没有服务、API 不可读或插件未注册绝不写成 `PASS`。脚本不会启动、停止或修改已有实例，结果中的 `usedRealDsh=true` 只有在显式确认后才会出现。GitHub 手动 workflow 为 [`compatibility.yml`](../../.github/workflows/compatibility.yml)。

如果希望门禁自己启动 pinned 的真实 runtime，可先在包目录执行 runtime 的 `npm ci`，再传 `-StartPinnedRuntime -RuntimeRoot .\tools\runtime`。脚本会使用临时 `DSH_HOME`、临时 Profile 和 loopback 端口，结束时只停止它自己启动的进程并清理临时目录；runtime 缺失或真实启动失败返回 `UNAVAILABLE`/非零。默认不启用，避免碰到你已有的 DSH 实例。

## 使用前先记住

1. 本插件默认不访问插件商店、不上传诊断报告；但启动器发现本机没有固定 runtime 且没有传 `-NoInstall` 时，会按包内 lockfile 执行一次 `npm ci`，这一步可能联网。
2. 想保证本次启动不自动联网，请先准备好 runtime 或 `PATH` 中的 `dsh`，并使用 `-NoInstall`。
3. 当前版本不提供默认热切换（Hot-swap）。更新插件必须停止旧实例后重新启动；`plugin_hotswap_check` 只报告能力合同，不执行切换。
4. `plugin_check`、`npm test`、fixture 和 `Test-DSHStandalone.ps1` 主要是离线或合成检查；通过它们不等于真实 DSH Web、Host API、浏览器页面或生产任务已经验证。

最短复制入口见 [`DEBUG-QUICKSTART.md`](DEBUG-QUICKSTART.md)。

## 这个插件解决什么问题

- 启动前检查 Profile、bundle、patch、运行时（runtime）和本地依赖是否一致。
- DSH 启动失败或 Web ready 后发现第三方插件失败时，生成可逆的 `disabled: true` Guard patch，并最多进行一次受控重启。
- 启动冲突时不杀掉已有 DSH，也不覆盖已有 Profile；默认切换到新的 loopback 端口和隔离 Profile。
- 在 Web 页面提供鼠标来源检查器和诊断页，报告插件、Module、Slot、客户端错误、主机端（Host）插件清单、Tool Call 元数据和运行时线索。
- 在客户端保留最多 80 条脱敏诊断 breadcrumb（面包屑事件），串起启动处置、鼠标来源变化、插件清单刷新、Slot/客户端错误；超出上限会记录丢弃计数，不保存 Tool 参数、正文、DOM 文本或凭据。
- 比较两次脱敏诊断/事故报告的状态、计数和 Issue code；检测到消息、路径、命令或凭据字段时只返回 `MANUAL_REVIEW`。
- 提供 Profile/Workspace 快照（snapshot）、known-good 恢复、事故采集（incident capture）、脱敏 trace/eval、资源压力和失败归档工具；标记为敏感的条目、`.env*` 和 `.credentials*` 只记录排除原因，不复制内容，恢复时也不会覆盖它们。
- 根据脱敏插件清单、失败证据和 Profile manifest 生成只读插件二分定位计划，给出安全第三方候选顺序；不会自动禁用插件、不会写 Profile、不会执行命令。
- 注册只读 `plugin_check` 工具，按 registry、skill、collection、bundle/tool-bundle 形态检查 manifest、patch、构建陷阱、Profile Bundle 安装文档和受保护核心 row；不执行目标插件、不安装依赖、不联网。
- 注册只读 `plugin_hotswap_check` 工具，观察 Host 是否声明稳定、权威、带串行队列/核心保护/回滚的生命周期合同，并检查目标插件的核心、runtime-only、ancestor-disabled、动态 `!!js` 风险；即使返回 `SUPPORTED` 也不执行切换。
- 注册只读 `plugin_hotswap_preflight` 工具，对一个明确指定的候选仓库做有界源码静态预检；它会提示 shell/包管理器执行、私有生命周期 API、缓存清理、无鉴权控制面、非原子 patch、缺少回滚/串行队列/核心保护/测试/CI 等线索，但绝不 import、安装、执行或修改候选。
- 注册只读 `dsh_agent_report` 工具，在 Host 提供持久化 SessionQuery 或当前内存会话时生成 Token、工具调用、失败、风险和内置估算费用报告；没有可读 Session 服务时返回 `UNAVAILABLE`，不会调用模型、执行命令、读取凭据或写回历史。
- 离线静态预检 JS/MJS/CJS 的 `inject` 与 `ctx.*` 服务依赖；不执行插件代码，动态访问或超出扫描上限时只返回人工复核。
- 根据 Profile/package 元数据（metadata）生成离线依赖图，报告缺失依赖、循环和未引用本地包；不运行 npm/pnpm、不安装依赖、不执行 package code。
- 对脱敏 Trace 事件做有限窗口的重复循环分析；只输出重复次数、索引和稳定签名，敏感字段会转人工复核。
- 对 Agent/Workflow 生命周期做有界递归分析；深度超限返回 `RECURSION_DETECTED`，动态、错配或未闭合标记返回 `MANUAL_REVIEW`，不回显 ID 或正文。
- 运行时任务守护观察 Tool Call 循环、子任务递归和中断；默认只在冷却窗口内发送一次脱敏提示，永远不终止任务、杀进程、重启 Host、禁用插件或修改 Profile。
- 在 Host 明确声明 no-tools planner 能力时，才允许创建隔离的修复规划 Session；普通 Host 上保持 `UNAVAILABLE`，不会偷偷创建一个带工具的 Session。

当前版本明确不提供插件热切换动作：不会在运行中启停或重启插件，不会监听 `package.json` 自动安装/卸载，也不会用未经 DSH 官方确认的 `_dispose`、`refresh` 或 ESM 缓存清理来假装模块已经重新加载。新增的 `plugin_hotswap_check` 只是只读能力探测，输出 `SUPPORTED`/`PARTIAL`/`UNAVAILABLE`/`MANUAL_REVIEW` 分层判定，不代表模块已经重载或业务仍可用。相关 GitHub 项目的可吸收设计和拒绝原因见 [`RESEARCH.md`](RESEARCH.md) 与仓库根目录的 [`RESEARCH-ECOSYSTEM.md`](../../RESEARCH-ECOSYSTEM.md)。

诊断结果是证据和线索，不会把“发现失败插件”夸大成已经证明根因，也不会把“报告写入成功”夸大成 DSH 已经恢复。

## 安装

使用仓库中的一键入口（推荐显式固定诊断默认端口）：

```powershell
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
```

Debug 包装器默认使用 `debug` Profile 和 `127.0.0.1:3081`，首次运行把当前目录中的 bundle 离线安装到该 Profile。要求本次启动不自动联网时，请使用：

```powershell
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
```

`-NoInstall` 要求本机已有 pinned runtime；缺少 runtime 会直接失败并说明原因。省略 `-NoInstall` 时，如果本机没有 pinned DSH runtime，启动器会按 `tools/runtime/package-lock.json` 执行一次 `npm ci`，这一步可能联网；这里的“离线”只表示 bundle 安装不访问插件商店。缺少 lockfile 或 lockfile 不一致会 fail closed，不会用 `npm install` 静默重解依赖。启动器对本机 Web readiness 探测会明确绕过系统 HTTP 代理，避免代理返回的 `502` 被误判成 3081 端口冲突。需要后台运行时使用 `Start-DSH-Debug.vbs`。

也可以通过 DSH CLI 安装本地包：

```powershell
dsh plugin --profile debug add . --offline
```

更新已经安装到 Profile 的本地版本时，先停止旧实例，再用 `-ForcePluginInstall` 覆盖已安装 bundle；普通再次启动只会复用已安装版本，不会猜测源码是否变化：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoInstall -NoBrowser
```

旧的 provenance Profile 不会自动迁移；请先备份并核对旧 Profile，再按仓库中的 [`MIGRATION-MANIFEST.md`](../../MIGRATION-MANIFEST.md) 的边界重新安装 canonical `dsh-plugin-debug` bundle。

`Start-DSH-Combined.*` 只在你先运行 `tools\Install-DSH-Agents.vbs` 后才会启用可选的 Kimi/Codex Agent 覆盖层（overlay）；覆盖层不是 Debug 核心依赖。

## 启动故障处理

启动器默认开启一次性 Crash Guard。它遵守以下顺序：

1. 读取当前 Profile 的插件清单和安全候选。
2. 只考虑明确属于第三方插件、且能由当前 Profile manifest 映射的候选；核心 `@deepseek-ai/*` 和 runtime `include` 项不会自动禁用。
3. 对启动日志或 `pluginInventory/list` 已观察到的失败插件写入 Guard state 和可逆 patch。
4. 最多重启一次并重新等待 Web ready；第二次仍失败时进入 `degraded`，不会无限自愈。

因此“有问题就直接禁用”不是无条件删除：它只自动隔离有明确证据的安全第三方候选，无法归因时保留人工复核，并把启动状态记为 `degraded`，不会把“拒绝猜测”错误报告成 `healthy`。默认 Debug 启动器最多只做一次受控重启；无法安全隔离的失败不会触发盲目重启。

每次启动还会在当前 `StateRoot` 写入 `startup-incident.json` 启动处置回执。它记录本次启动是 `healthy`、`restarting`、`recovered`、`degraded` 还是 `failed`，以及关联 ID、重启次数、被隔离的插件 ID 和可查看的本地证据文件名。回执不写原始日志、Tool 参数、凭据或完整路径；`incident-capture` 会在存在时把它纳入 `components.startup`，方便后续诊断和复现。

如果目标端口已有其他 DSH 实例，而目标 Profile 尚未安装 Debug bundle，启动器默认自动使用类似 `web-debug-3082` 的隔离 Profile。原实例、原端口和原 Profile 不会被修改。要恢复严格拒绝模式，可传：

```powershell
.\tools\Start-DSH.ps1 -Profile debug -Port 3081 -NoIsolateOnConflict -NoErrorDialog
```

## 页面通知和修复 Session

Web Client 会把 Host inventory 中的 failed plugin、动态插件运行错误和 Slot 渲染错误显示在诊断页，并持续刷新运行时状态。页面提示只报告“发现了什么”，不会伪造因果结论。

诊断页还会显示本地时间线。它是一个固定上限的环形缓冲，事件只有类别、时间、状态、插件/Module/Slot 标识和经过脱敏的短摘要；`getDiagnosticBreadcrumbs()` 与导出的诊断 JSON 会同时返回 `limit`、`dropped` 和 `truncated`，便于判断是否因为事件太多而丢失早期线索。

启动处置完成后，页面 URL 只带有限的 `dsh_debug_guard=isolated` 和脱敏 incident ID，用于显示通知和区分不同故障；它不会携带插件名称、日志、Tool 参数或路径。自动诊断 Session 还有一层独立的 Host 合同：必须同时存在 `diagnosticSessionPolicy.automatic === true`、`mode === 'no-tools'`，以及 Host 提供的 `sessions.createNoTools(request)`（或等价的 `diagnosticSessionPolicy.createNoTools`）工厂。工厂必须接受 `mode: 'no-tools'`、空工具列表和 metadata-only 请求，并返回可验证的 `mode: 'no-tools'`、`tools: false`、`approval: false`、`execution: false` 能力证明。普通 `sessions.create()` 不会被当成安全入口；缺少专用工厂或能力证明时，页面显示 `UNAVAILABLE`，不会创建 Session，也不会发送 prompt。

修复规划默认是只读 dry-run：

```powershell
.\Debug-DSH.ps1 -Action repair-assist -Profile debug -Port 3081
```

只有 `host.describe` 明确声明 no-tools planner 能力时，这个动作才会创建隔离的最小 Session；它会拒绝已有用户 Session、工具调用、审批事件、执行事件、未知字段和过期证据。当前 DSH rc.6 未提供该能力时，结果为 `UNAVAILABLE`，这是预期的安全结果。任何实际 patch 应使用显式 `repair-apply -Force`，并保留 receipt 供回滚。

## 插件仓库健康检查（`plugin_check`）

安装本插件后，DSH Host 会自动注册一个只读的 `plugin_check` 工具。它适合在安装或发布前检查一个插件仓库，不会替你运行插件，也不会把检查通过写成“真实 DSH 已启动”。工具有三个动作：

- `check`：检查一个仓库目录；
- `scan`：检查父目录下有 `dsh-` 前缀的多个仓库；
- `schema`：返回当前检查项和严重等级。

`path` 传仓库或父目录的绝对路径，`strict=true` 会把 warning 也升级为失败。报告会显示 `kind`、`verdict`、`findings`、修复提示、资源限制和 `hub.status`。`checks.total/passed/failed/warned/skipped` 只统计当前 `kind` 适用的唯一规则，`checks.results` 会逐项列出状态，`checks.findingCount` 另算具体 finding 条数；因此 registry 报告不会把 bundle 的规则也假装成已检查，离线 Hub 也会明确算作 `skipped`。当前 Hub 是安全的离线模式：状态固定明确为 `skipped`，不调用 `gh`、Git 或网络，不读取本机 GitHub 登录状态；因此它不能证明某仓库已经被 Hub 收录。

检查重点包括：

- `package.json` 的名称、入口、patch 声明和发布 `files`；
- `cordis.patch.yml` 的 `insert/update/disable` section、缺少 `id`、重复 row、核心 row 覆盖和 package identity；
- `main`、`types`、patch、registry `main/client.main` 的仓库根路径围栏，拒绝绝对路径、`..` 逃逸、符号链接和 junction 真实路径逃逸；
- TypeScript 扩展名 import、`tsconfig extends`、`rewriteRelativeImportExtensions`、lib 产物残留 `.ts` import、安装生命周期脚本和扫描资源预算；
- registry 的 `dsh.plugin.json`、根目录或 `skills/*/SKILL.md`、collection 的 `catalog.json` 最小契约；
- README 是否给出标准 `dsh plugin --profile <profile> add <plugin>` 安装例子。

报告还会固定给出 `mode=offline`、`networkAccessed=false`、`commandsExecuted=false`、`targetMutated=false`、`executesPluginCode=false` 和 `truncated`。如果资源预算耗尽，结果会 fail-closed，不会把“只扫描了一部分”算成通过。`plugin_check` 是静态健康检查，不是完整 YAML 解析器、真实构建器、npm 安全扫描器或 Hub 发布门禁。候选插件的 `npm test`/`npm run build` 通过，也不能替代当前仓库的 fresh-clone、DSH runtime 和 Web readiness 验证。

当前报告协议是 `schemaVersion=2`。这是有意的版本变化，因为 `checks` 现在按仓库形态统计适用规则，并增加了离线安全字段、截断向上传播和逐项 `checks.results`。旧消费者不能把 v2 的计数当作 v1 语义；`schema` action 返回的每个检查项也带有同一个 `schemaVersion`，接入方应按版本读取。

## 热切换能力探测（`plugin_hotswap_check`）

这是吸收 `dsh-hotswap` 研究结论后的安全接口：它只读取 Host inventory、公开能力合同和目标条目的元数据，不执行 `update`、`dispose`、`refresh`、`_dispose`，不清理 ESM/CJS 缓存，不写 `cordis.patch.yml`，不安装依赖，也不监听 `package.json`。`@deepseek-ai/*`、`include:*` 组合条目、Debug 自身和已知 DSH 核心名称都会进入保护门；即使 loader 给它们分配了自定义 ID，也不会被当成安全第三方候选。可选的 `pluginId` 只用于精确匹配一个条目；省略时报告 Host 全局能力。

它还会对证据完整性 fail-closed：如果 inventory 被截断、目标没有 live fiber，或目标的祖先链超过有界扫描深度，就不会把候选标成 `SUPPORTED`，而是返回 `MANUAL_REVIEW`/`PARTIAL` 并给出对应 finding。这样未来即使有人把报告接到独立的执行器，也不会因为“只看到了前 100 条”或“看起来像运行中”而错误授权。

返回的 `verdict` 只有四种：`SUPPORTED`（Host 明确声明稳定、权威、带可审计版本的完整合同，并且指定目标通过元数据门禁，仍未执行切换）、`PARTIAL`（合同来源/稳定性/版本可审计，但缺少部分操作或安全字段；省略 `pluginId` 时只做 Host 级观察，即使合同完整也不会针对具体插件返回 `SUPPORTED`）、`UNAVAILABLE`（没有可读 inventory，或合同没有被官方 DSH Host 标记为权威、稳定并带版本）和 `MANUAL_REVIEW`（核心、runtime-only、祖先禁用、动态 `!!js` 或歧义匹配）。最小可审计合同必须包含 `source=dsh-host`（或 `official=true`）、`stable=true`、非空 `version`、`entry.update`/`entry.dispose`/`entry.refresh` 三个操作，以及 `serialQueue=true`、`coreProtection=true`、`rollback=true`；缺少操作/安全字段是 `PARTIAL`，缺少权威来源/稳定标记/版本是 `UNAVAILABLE`。`execution` 永远是 `NOT_ATTEMPTED`，`executionAttempted`/`executionVerified` 永远是 `false`，`actionsExecuted` 为空，`targetMutated` 永远是 `false`；任何人都不能把 `SUPPORTED` 当成模块已经重载或真实业务仍可用。当前 rc.6 runtime 可能加载官方 HMR 服务，但“观察到 HMR”不等于获得插件修改权；没有公开生命周期合同时仍返回 `UNAVAILABLE`。

## 热切换候选源码预检（`plugin_hotswap_preflight`）

这个工具解决的是“要不要吸收某个 hotswap 仓库”的前置判断，不是热切换执行器。它只读取你明确传入的候选目录，最多扫描 400 个文件、单文件 512 KiB、总计 4 MiB；会跳过 `.git`、`node_modules`、`sbom` 等依赖/生成目录，拒绝符号链接，并把扫描截断或读取失败报告出来。

```powershell
.\tools\Preflight-DSHHotswap.ps1 -Path C:\path\to\candidate
# 严格模式：任何静态 warning 都要求人工复核
.\tools\Preflight-DSHHotswap.ps1 -Path C:\path\to\candidate -Strict
```

它可以发现 shell/`npm install`、`_dispose`/`refresh`、模块缓存清理、无更强认证的控制面、`cordis.patch.yml` 写入、缺少原子写入/回滚/串行队列/核心保护、缺测试/CI/许可证等静态信号。`PASS` 只表示在这组有界规则中没有发现线索，不表示候选兼容 DSH；`MANUAL_REVIEW` 也不是“已确认漏洞”。整个过程固定返回 `networkAccessed=false`、`commandsExecuted=false`、`executesPluginCode=false`、`targetMutated=false`、`execution=NOT_ATTEMPTED` 和 `actualHotSwap=false`。

## Agent 运行报告（`dsh_agent_report`）

这是吸收 [dsh-whale-report](https://github.com/SenmuuuuW/dsh-whale-report) 后保留的“可读报告”能力。它把 Session、Token（含缓存命中和缓存写入）、模型、工具调用、失败、重试、风险和本地估算费用整理成一份中文报告，报告本身由确定性代码生成，不调用模型，所以生成报告消耗 0 token。

调用示例：

```text
dsh_agent_report(preset="weekly")
dsh_agent_report(preset="daily")
dsh_agent_report(
  preset="custom",
  from="2026-08-01T00:00:00Z",
  to="2026-08-17T00:00:00Z"
)
```

支持的区间是 `daily`、`24h`、`weekly`、`monthly`、`yearly` 和 `custom`。完整历史需要 Host 提供 `sessionQuery`；如果只有 `ctx.sessions`，报告会明确写“仅当前内存会话”；没有可读 Session 服务则返回 `UNAVAILABLE`，不会用测试 fixture 冒充真实历史。

费用是包内固定价格的估算，不是 DeepSeek 账单，也不会联网抓价格。报告有界读取最多 500 个 Session、最多 1,000,000 条事件；读取失败或达到上限会返回 `PARTIAL`，不能当作完整账单。

安全边界：

- 只读 Session，不写回历史，不执行 Tool、命令、PowerShell 或 shell；
- 不读取 `.credentials.yaml`、`.env`、API key 或其他凭据；
- 不上传报告，不请求余额，不调用外部价格接口；
- 原始命令、Tool 错误正文、密钥原文和完整 Session ID 不进入报告；
- `rm -rf`、删库、关机等内容只是 Session 事件里的风险文本线索，不代表 Debug 执行过这些命令；
- 上游的余额探针、浏览器 UI、外部价格/凭据读取和 `rm -rf lib` 构建脚本没有被复制进本包。

真实 Host 没有历史 Session 时，可以用明确提供的脱敏 JSON 复现报告算法：

```powershell
.\Debug-DSH.ps1 `
  -Action agent-report `
  -InputPath .\tools\fixtures\agent-report-document.json `
  -Preset weekly
```

输入必须是 `schemaVersion: 1` 的版本化文档，示例见 [`tools/fixtures/agent-report-document.json`](tools/fixtures/agent-report-document.json)。入口只读取这个明确文件，不自动扫描 `DSH_HOME`、Profile 或目录，不联网、不执行 JSON 中的命令，并拒绝符号链接输入。不要把 `.env`、`.credentials*`、密钥、私钥、证书或未脱敏的 Session 文件交给它；报告默认输出到 stdout，且不输出原始 Session ID、命令、错误正文或 Secret 原文。离线 JSON 能证明报告算法和脱敏边界可用，但不能替代真实 DSH 有数据 SessionQuery 的验证。

因此，这个功能可以吸收并使用，但它是“本地只读 Agent 报告”，不是账单系统、命令审计的执行证明，也不是把上游完整插件作为运行时依赖安装进来。

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

接口和 `$DSH_HOME/guardian/events.jsonl` 只包含有界计数、事件类别、深度和不可逆指纹，不返回原始 Session ID、Tool 参数、消息正文或凭据。内存中的最近事件窗口、单条事件元数据和磁盘事件日志均有界：默认保留当前文件加两个轮转文件，每个文件最多 256 KiB；可在 Guardian 设置中用 `eventLogMaxBytes`（1 KiB–4 MiB）和 `eventLogMaxFiles`（2–10）调整。轮转只处理 Debug 自己的 `guardian/events.jsonl*` 文件，不读取或清理其他 DSH 数据。长期运行时仍不要把本地日志提交或上传。守护不会终止任务、杀进程、重启 Host、禁用插件或修改 Profile；`agents` 服务或这些事件在 Host 中缺失时，插件仍可启动并保持 `UNAVAILABLE`/空闲状态。

这里的 observer-only 只描述 Guardian。整个包还包含有明确边界的 Crash Guard 和 Runtime Supervisor：它们在公开 Debug 启动器中可以停止已确认的 DSH 子进程、生成可逆 Guard patch，并最多重启一次；不能把这部分描述成无副作用观察。底层 `tools/Start-DSH.ps1` 直接调用时默认不启用 Crash Guard。

Host API 的 `BaseUrl` 默认必须是 loopback（例如 `127.0.0.1`、`localhost` 或 `::1`）。访问受信任的远端 Host 前，必须显式设置 `DSH_DEBUG_API_ALLOWED_HOSTS`，否则 `session.history`、`pluginInventory/list` 等查询会在发出请求前失败：

```powershell
$env:DSH_DEBUG_API_ALLOWED_HOSTS = 'debug-host.example'
```

重启前可以通过统一入口读取守护状态。空闲时返回退出码 0 和 `SAFE_TO_RESTART`；存在活动 Session 或未完成操作时返回退出码 2 和 `BUSY_DO_NOT_RESTART`，脚本只给出建议，不会自行重启：

```powershell
.\Debug-DSH.ps1 -Action guardian-status -Profile debug -Port 3081
.\tools\Test-DSHGuardianStatus.ps1
```

## 测试

测试源码和脱敏 fixture 会随 GitHub 源码一起发布，便于别人复现实现和检查发布边界：

```powershell
# 以下命令从仓库根目录（包含 scripts/ 和 packages/ 的目录）开始
Push-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1

Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHPluginIntegration.ps1 -SkipCompatibility
.\tools\Test-DSHLauncherConflict.ps1
.\tools\Test-DSHCrashGuard.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1 -UnresolvedPluginFailure  # 负向：无安全映射时 fail closed，不禁用、不二次重启
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

`tools\fixtures` 中的 JSON/HTML 是合成且脱敏的输入数据，会被 trace 和浏览器契约测试直接引用。Trace fixture 只保存事件类型、调用键名、权限枚举、错误代码和 pending/错误语义，不保存 raw arguments、Tool result 正文、Token 或危险命令。Recovery fixture 会证明 `.env` 只标记为存在但排除，快照和 restore 都不会接触其内容。Crash Guard、启动冲突和 runtime supervisor 的 fake DSH 会在测试运行时创建到临时目录，测试结束后清理；仓库中没有真实 Profile、日志、凭据或崩溃转储。

`Test-DSHPointerBrowser.ps1` 需要 `python.exe`、`npx` 和可用的 Playwright 浏览器 daemon；缺少这些依赖时只报告 `UNAVAILABLE`，不会把静态 HTML 加载冒充成真实 DSH Web 验证。

上面列出的核心命令必须取得退出码 `0`。`Test-DSHPointerBrowser.ps1` 是环境依赖型可选检查，只有它在缺少浏览器运行时而返回退出码 `2` 时才可记录为 `UNAVAILABLE`；其他非零退出码都应视为失败。无论是否运行浏览器检查，`Verify-Publication.ps1` 都必须输出 `result = PASS`，并且不能把 `UNAVAILABLE` 写成“真实 DSH Web 已验证”。

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

先记住两个边界：`Verify-Publication.ps1` 必须在 `npm ci` 之前运行；安装依赖后不要在同一棵树上再次运行它。安装后的 `node_modules` 只用于测试，真正的 `npm pack` 要从排除 `node_modules` 的 pack-only staging 目录运行。历史 `RELEASE-MANIFEST.json` 中的文件数只属于旧的已验证提交，不能直接套用到未提交候选。

1. 在 `src` 或 `tools` 修改源码，同时新增或更新对应的 Node/PowerShell 回归测试。
2. 如果功能改变了公开行为，先按 SemVer 修改 `package.json` 的 `version` 并同步 `package-lock.json`；版本不要放到构建之后才改。
3. 运行 `npm run check`，它会重新构建 `lib`、更新 `bundle-manifest.json` 并运行 Node 测试。
4. 运行 `Test-DSHStandalone.ps1`、启动冲突夹具和发布验证器；会启动 fake/loopback 测试进程的命令不能当作纯静态检查。
5. `npm run check` 会重建 `lib` 和 `bundle-manifest.json`；先比较生成的 `src`/`lib` 文件哈希，再从不含依赖目录的 pack-only staging 运行 `Verify-Publication.ps1` 和 `npm pack --dry-run --json --ignore-scripts`，最后同步 `SOURCE-SNAPSHOT.md`、`RELEASE-MANIFEST.json` 和必要的文档。
6. 先在本地做一次可审阅的 candidate source commit 并推送；从远端回读 `sourceCommit` 后，再从该提交创建 fresh clone 重跑测试。只有 fresh clone 通过后，才用单独的 evidence commit 更新发布清单中的 `publishedCommit`、两个 UTC 验证时间和 `status`，再推送 evidence commit。版本变更后用 `npm install --package-lock-only --ignore-scripts` 同步 lockfile，再运行 `Verify-Publication.ps1` 检查四处版本一致。

发布前候选状态、GitHub remote、fresh clone 验证结果会记录在仓库根目录的
`RELEASE-MANIFEST.json` 和 `SOURCE-SNAPSHOT.md`；本地测试通过不等于真实 DSH
生产实例已经验证。

## 研究和吸收边界

本项目参考了公开的 `dsh-doctor`、`dsh-fail-logger`、`dsh-sentinel`、`dsh-turn-rewind`、`dsh-checkpoint-rewind`、`dsh-clawrouter`、`dsh-plugin-doctor`、`dsh-ci-doctor`、`dsh-capability-inspector` 和 `harness-doctor` 等项目的公开 README/代码结构，但没有复制它们的源码，也不把它们加入运行时依赖。当前吸收的是可验证的设计形状：只读 doctor、失败去重、可逆 snapshot、执行前安全闸门、bounded restart、分层 readiness、能力矩阵和 schema 化 support bundle。

本轮新增的研究结论也明确写入仓库根目录的 [`RESEARCH-ECOSYSTEM.md`](../../RESEARCH-ECOSYSTEM.md)：`npm pack --ignore-scripts` 隔离安装、临时 `DSH_HOME`、Web readiness、rollback receipt、失败签名 ledger、单项降级、显式 allowlist 和 hotswap 的核心保护/串行队列都只是设计参考。当前已经实现的是离线 metadata-only 检查、发布边界验证、可逆 Guard、页面通知和受限诊断 Session；真实 DSH Web readiness、runtime/native 模块隔离、持久 CI ledger、完整 support bundle 和运行时热切换仍是未验证或未开放能力，不能从研究结果推断为已支持。

尚未默认加入的能力包括：常驻文件/HTTP watcher、模型二次审查危险命令、真正的 durable rewind、自动安装依赖、任意进程清理、自动 Git bisect、外部 telemetry、持久 CI ledger 和无 allowlist 的 support bundle。这些功能会扩大权限或运行时边界，必须先有 DSH 官方 API、明确的安全策略和独立回归测试。

## 发布边界

仓库只公开 `packages/dsh-plugin-debug` 一个运行时包。插件商店目录和能力已经删除。测试程序属于源码仓库的一部分，但测试生成的临时目录、真实 DSH 状态、日志、Session、凭据和本机缓存永远不应上传。

## 许可证

MIT
