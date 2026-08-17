# dsh-plugin-debug（DSH 调试插件）

这是 npm 和 GitHub 默认显示的中文说明。它把 DSH 检测、调试、恢复、插件健康检查、崩溃隔离、事故取证、Trace 分析、任务守护和一键启动能力合并到一起，运行时只有一个包：`dsh-plugin-debug`。更长的逐项中文手册见 [`README.zh-CN.md`](README.zh-CN.md)；两份文档都以当前源码和测试为准，不把英文术语当成额外组件。Windows 上推荐使用 PowerShell 7（`pwsh`）；PowerShell 5.1 只用于兼容性检查。

本包不依赖插件商店，也不会安装或调用 `dsh-plugin-store`。旧的 provenance、debug-suite 和 one-click 目录已经迁移后从项目树移除；已有旧 provenance Profile 需要显式迁移或重新安装。发布状态、实际 npm 文件清单和 GitHub 推送状态分别以仓库中的 [`RELEASE-MANIFEST.json`](../../RELEASE-MANIFEST.json)、[`SOURCE-SNAPSHOT.md`](../../SOURCE-SNAPSHOT.md) 和远端提交为准。这里使用相对链接，打开 tag/source archive 时会继续指向同一份快照，不会跳到另一个 `main` 提交。

公开证据记录中的 `0.8.4` source commit 是
`7fce25118098cbceb7f3f24fa391d75324318b11`；该提交已经推送到 GitHub，精确远端 fresh clone 已通过发布边界、依赖审计、Node/PowerShell、Standalone、离线 integration、SBOM 和 108 文件 pack 检查。本包是 GitHub source release，不发布到 npm registry；真实有数据 Session、模型请求、第三方插件安装和跨平台兼容仍未证明；真实 Host/Web compatibility lane 仍需显式 opt-in，不能把 `UNAVAILABLE` 写成 `PASS`。`dsh_agent_report`、`plugin_check` 和 hotswap 能力仍按只读、脱敏、fail-closed 合同运行。

## 小白快速开始

完整的傻瓜式步骤见 [`DEBUG-QUICKSTART.md`](DEBUG-QUICKSTART.md)。最安全的启动方式是：

```powershell
Set-Location .\packages\dsh-plugin-debug
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
```

`-NoInstall` 要求本机已经有固定版本 DSH runtime 或 `PATH` 中存在 `dsh`；缺少 runtime 时会直接提示，不会偷偷下载。只有在你明确同意联网准备 runtime 时，才单独执行：

```powershell
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
```

启动后打开 `http://127.0.0.1:3081`。如果只想做离线检查、不启动 DSH：

```powershell
npm test
.\Test-DSHStandalone.ps1
```

更新已经安装到同一个 Profile 的本地源码时，先停止旧实例，再强制覆盖 bundle；这不是热切换：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoInstall -NoBrowser
```

结果这样看：`PASS` 是通过，`UNAVAILABLE` 是本机缺少对应服务，`PARTIAL/WARN` 是证据不完整，`FAIL` 是检查失败。报告写出来不等于生产 DSH 已恢复。

## 质量、供应链与真实兼容性门禁

在源码包目录中可以运行下面的门禁。它们不需要真实模型请求；`typecheck` 在当前纯 JavaScript/PowerShell 项目中会明确输出 `SKIPPED`，不会把没有 TypeScript 当成“类型检查通过”：

```powershell
npm ci --ignore-scripts
npm run lint
npm run format:check
npm run typecheck
npm run coverage
npm run check:workflow-pins
npm audit --registry=https://registry.npmjs.org --audit-level=high
npm run check:runtime-lock
npm run sbom:check
```

`sbom/dsh-plugin-debug.spdx.json` 和 `sbom/dsh-plugin-debug.cdx.json` 是由锁文件确定性生成的 SPDX 2.3 与 CycloneDX 1.5 清单；`npm run sbom:check` 会拒绝手工修改或漂移。`npm run check:runtime-lock:installed` 需要先执行固定 runtime 的 `npm ci`，然后逐项核对 `tools/runtime/node_modules` 的版本。

真实 DSH Web/Host 兼容性检查是手动、明确 opt-in 的独立门禁，不会调用 fixture、模型、插件安装或热切换：先启动你要验证的真实 DSH，再运行：

```powershell
pwsh -NoLogo -NoProfile -File .\tools\Test-DSHCompatibility.ps1 `
  -ConfirmRealDsh -BaseUrl http://127.0.0.1:3080
```

脚本会真实读取 Web 首页、`host.describe` 和 `pluginInventory/list`，并要求清单中出现 `dsh-plugin-debug`。没有 `-ConfirmRealDsh` 会返回 `UNAVAILABLE`/退出码 `2`；服务不存在、Host API 不可读或插件未注册不会被写成 `PASS`。它不会启动、停止或修改已有 DSH 实例，也不会读取模型或会话正文。GitHub 上对应的手动 workflow 是 [`compatibility.yml`](../../.github/workflows/compatibility.yml)。

如果要让门禁自己启动 pinned 的真实 runtime，可在已经完成 runtime `npm ci` 后额外传 `-StartPinnedRuntime -RuntimeRoot .\tools\runtime`。它会使用临时 `DSH_HOME`、临时 Profile 和 loopback 端口，检查结束后停止自己启动的进程并清理临时目录；缺少真实 runtime 或启动失败返回 `UNAVAILABLE`/非零。默认不启用这个模式，避免碰到你已有的 DSH 实例。

## 适用范围

它适合在 PowerShell 7（`pwsh`）中排查以下问题；PowerShell 5.1 仅用于兼容性检查：

- DSH Profile、bundle、patch 或本地运行时（runtime）清单不一致；
- Web 启动失败、第三方插件加载失败、启动后反复崩溃；
- 页面元素的插件来源不清楚、Slot/Module 归属冲突；
- Tool Call、权限元数据、会话（Session）历史或上下文装载异常；
- 需要生成脱敏事故包、Trace baseline、可逆快照或受限修复（repair）回执。

诊断输出是证据和线索，不会把“发现失败插件”写成已经证明根因，也不会把“报告写入成功”写成 DSH 已经恢复。

## 安装与一键启动

从本目录运行：

```powershell
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoBrowser
```

Debug 包装器默认使用 `debug` Profile、`127.0.0.1:3081`，并离线安装本地 bundle。首次启动如果本地还没有 pinned DSH runtime，仍可能先通过 npm 下载 runtime；这里的“离线”只表示 bundle 安装不访问插件商店。默认 runtime 位于 `tools/runtime`；需要把 runtime 放在别处时，可以在启动前设置 `DSH_RUNTIME_ROOT`。启动器对本机 Web readiness 探测会明确绕过系统 HTTP 代理，避免代理返回的 `502` 被误判成 3081 端口冲突。也可以直接使用 DSH CLI（要求 `dsh` 已经在 `PATH`）：

```powershell
dsh plugin --profile debug add . --offline
```

更新已经安装到 Profile 的本地版本时，先停止旧实例，再用 `-ForcePluginInstall` 覆盖已安装 bundle；普通再次启动只会复用已安装版本，不会猜测源码是否变化：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoBrowser
```

旧的 provenance Profile 不会自动迁移；请先备份并核对旧 Profile，再按仓库根目录 [`MIGRATION-MANIFEST.md`](../../MIGRATION-MANIFEST.md) 的边界重新安装 canonical `dsh-plugin-debug` bundle。

`Start-DSH-Combined.*` 是可选的 Agent 覆盖层（overlay）入口。只有显式运行 `tools\Install-DSH-Agents.vbs` 后才会安装覆盖层；它不是 Debug 运行时依赖，也不是插件商店。

## 能力总览

| 能力 | 提供内容 | 重要边界 |
| --- | --- | --- |
| 页面来源标注 | 读取 data-dsh-plugin、data-dsh-module、CSS、Slot，显示插件、Module、Slot 和证据等级 | 未标记的 DOM 显示未知，不猜测来源 |
| 主机端（Host）诊断 | 上下文、插件健康、会话（Session）健康、安全审计、资源压力、失败归档 | API 不可用时保留 PARTIAL/UNAVAILABLE |
| 崩溃防护（Crash Guard） | 启动日志和 inventory 识别安全第三方候选，写入可逆 patch，最多重启一次 | DSH 核心包、runtime include、未知或歧义项不自动禁用 |
| 启动回执 | 写入 startup-incident.json，记录启动状态、关联 ID、重启次数和隔离插件 | 不写原始日志、Tool 参数、凭据或完整路径 |
| 客户端诊断时间线 | 80 条上限的脱敏 breadcrumb 环形缓冲，记录启动、鼠标来源、插件清单、Slot 和客户端错误顺序 | 超出上限记录 dropped；不保存 Tool 参数、正文、DOM 文本或凭据 |
| 快照/恢复（Snapshot/Recovery） | Profile、Workspace、known-good 检查点和追加式会话分支；敏感条目、`.env*` 与 `.credentials*` 只记录排除原因 | 不删除快照之后新文件，不重写原会话，不复制或覆盖敏感内容 |
| 受限修复（Repair） | 受限计划、allowlist、pre/post-image hash、receipt 和冲突回滚 | 用户改过文件时返回 ROLLBACK_CONFLICT，不覆盖改动 |
| 追踪/事故（Trace/Incident） | 仅元数据 Trace、baseline、autopsy、跨层事故包和 repro 导出 | 不保留 Tool 参数、结果正文、会话正文、Cookie 或 token |
| 插件二分定位 | 根据脱敏 inventory、失败证据和 manifest 生成候选顺序与人工步骤 | 只读计划，不自动禁用、不写 Profile、不执行命令 |
| 诊断报告对比 | 比较两次诊断/事故报告的状态、计数和 Issue code | 发现消息、路径、命令或凭据字段时返回 `MANUAL_REVIEW` |
| 插件静态预检 | 离线扫描 JS/MJS/CJS 的静态 `inject` 声明和 `ctx.*` 服务使用 | 不执行插件代码；动态访问和超出扫描上限转 `MANUAL_REVIEW` |
| 依赖图检查 | 读取 Profile/package manifest 和已有 package metadata，报告缺失依赖、循环和未引用本地包 | 不安装、不执行 package code、不修改 Profile；核心 DSH 包受保护 |
| 插件仓库健康检查（`plugin_check`） | 按 registry/skill/collection/bundle/tool-bundle 形态检查 manifest、patch、构建陷阱、安装文档和核心 row | 只读、离线、固定资源预算；不执行目标插件、不调用 gh/Git、不证明 Hub 收录或真实构建 |
| hotswap 能力探测（`plugin_hotswap_check`） | 只读观察 Host inventory、官方生命周期合同、核心保护、ancestor/runtime-only/`!!js` 状态和 HMR 线索 | 不调用任何生命周期方法，不重载、不启停、不改 Profile；`SUPPORTED` 也只表示“带版本的权威合同和具体目标通过安全门禁”，不是运行成功证明 |
| hotswap 源码预检（`plugin_hotswap_preflight`） | 对候选仓库做有界静态检查，标出 shell、私有 API、无鉴权控制面、patch 写入和缺少回滚/队列/测试/CI 等线索 | 不 import、不安装、不执行、不联网、不改候选；静态 finding 只是人工复核线索，不是运行时漏洞证明 |
| Agent/Session 报告（`dsh_agent_report`） | 从持久化 SessionQuery 或当前内存会话生成 Token、工具调用、失败、风险和内置估算费用的确定性报告 | 有界、metadata-only；不调用模型、不执行命令、不读取凭据、不写回 Session；没有可读 Session 服务时返回 `UNAVAILABLE` |
| Trace 循环与递归分析 | 在有界窗口/深度内识别重复调用和 Agent/Workflow 嵌套；输出脱敏事后线索 | 不阻塞运行时、不创建 Session、不执行 Tool；非法或不完整输入失败即停止 |
| 任务守护（Guardian） | 观察运行中的 Tool Call、子任务递归和中断，必要时发送一次短提示，提供状态接口并有界轮转事件日志 | observer-only：不终止任务、不杀进程、不重启 Host、不禁用插件、不修改 Profile |
| 热切换（Hot-swap） | 当前版本不提供运行时启停、热重启或自动挂载；只提供 `plugin_hotswap_check` 的只读能力探测 | 不调用 `_dispose`/`refresh`，不监听 `package.json`，不开放无鉴权 POST，不自动改写 Profile |

## 启动故障处理和页面通知

启动器按以下顺序工作：

1. 读取当前 Profile manifest、插件 inventory 和启动日志。
2. 只接受 manifest 明确映射的安全第三方插件候选。
3. 为已经观察到失败的候选写入 `guard-state.json` 和 `guard.patch.yml`。
4. 最多进行一次受控重启，并重新等待 Web ready。
5. 第二次仍失败时返回 `degraded` 或 `failed`，不会无限重试。

如果端口已经被其他 DSH 实例占用，启动器不会杀进程、覆盖 Profile 或强行接管端口；它会在可用时选择隔离 Profile 和 loopback 端口。页面通知只报告观察到的故障，不把相关性伪装成因果结论。通知本身不执行禁用、不执行命令，也不把“发现失败插件”写成“已经证明根因”。

页面只有在 Host 同时声明 `diagnosticSessionPolicy.automatic=true` 和 `mode=no-tools` 时，才允许自动创建隔离的诊断规划会话（Session）。普通 rc.6 Host 没有这个能力时返回 `UNAVAILABLE`，不会创建普通的可执行会话；用户已有会话、工具调用、审批事件和过期证据也会被拒绝。

## 插件仓库健康检查（`plugin_check`）

插件安装后，DSH Host 会注册一个只读工具 `plugin_check`，用于在安装或发布前检查插件仓库。它有三个动作：`check`（单仓库）、`scan`（扫描父目录中的 `dsh-*` 仓库）和 `schema`（查看检查项）。参数 `path` 是仓库或父目录路径，`strict=true` 会把 warning 升级为失败。

它会按仓库形态分流：`dsh.plugin.json` 走 registry 检查，根目录或 `skills/*/SKILL.md` 走 skill 检查，`catalog.json` 走 collection 检查，普通 `package.json` bundle 再检查 patch、入口、路径围栏和 TypeScript 构建陷阱。报告包含 `kind`、`verdict`、`findings`、修复提示、资源限制和 `hub.status`。`checks.total/passed/failed/warned/skipped` 只统计当前 `kind` 适用的唯一规则，`checks.results` 会逐项列出状态，`checks.findingCount` 另算具体 finding 条数；因此 registry 报告不会把 bundle 的规则也假装成已检查，离线 Hub 也会明确算作 `skipped`。

安全边界很明确：检查只读文件，不 import/require 目标插件，不运行 npm、build、shell、Git 或 `gh`，不联网，不读取本机 GitHub 登录状态，不访问 Profile。报告还固定给出 `mode=offline`、`networkAccessed=false`、`commandsExecuted=false`、`targetMutated=false`、`executesPluginCode=false` 和 `truncated`；资源预算耗尽会 fail-closed。Hub 始终以 `skipped` 明确表示未验证，不能把它理解成“已收录”。它也不是完整 YAML 解析器、真实构建器或 npm 安全扫描器；静态通过仍需 fresh-clone、DSH runtime 和 Web readiness 验证。

`plugin_hotswap_check` 是另一个只读工具：它可以观察 Host 是否声明稳定、权威且具备串行队列、核心保护和回滚的生命周期合同，并给出目标条目的保护/祖先/runtime-only/动态表达式风险。它永远不执行热切换，`execution=NOT_ATTEMPTED`、`targetMutated=false`；这不是 hotswap 实现或生产兼容性认证。

当前报告协议是 `schemaVersion=2`：这是有意的版本变化，因为 `checks` 现在按仓库形态统计适用规则，且增加了离线安全字段、截断传播和逐项 `checks.results`。旧消费者不应把 v2 的计数当作 v1 语义；`schema` action 返回的每个检查项也带有同一个 `schemaVersion`，接入方应按版本读取。

## 热切换能力检查（`plugin_hotswap_check`）

这是一个独立的只读 Host 能力报告，不是 `plugin_check` 的第四个 action，也不是热切换执行器。它只读取当前 Host 能公开提供的 loader inventory、生命周期合同和 HMR 线索，然后检查目标插件是否存在核心保护、runtime-only、祖先禁用、目标禁用或动态 `!!js` 风险。`@deepseek-ai/*`、`include:*` 组合条目、Debug 自身和已知 DSH 核心名称都会进入保护门；即使 loader 给它们分配了自定义 ID，也不会被当成安全第三方候选。

它还会对证据完整性 fail-closed：inventory 被截断、目标没有 live fiber，或祖先链超过有界扫描深度时，不会返回 `SUPPORTED`，而是降级到 `MANUAL_REVIEW`/`PARTIAL` 并给出对应 finding。这样只读报告不会把不完整观察结果误当成可执行授权。

调用工具时可以省略目标，先看 Host 级能力；也可以传入一个精确的插件 ID 或模块名：

```text
plugin_hotswap_check()
plugin_hotswap_check(pluginId="dsh-example")
```

顶层 verdict 的含义是：

- `SUPPORTED`：Host 明确声明了稳定、权威、带可审计版本的生命周期合同，且提供了具体目标；目标通过元数据安全门禁；只表示“具备可评估的合同”，本次没有执行热切换；
- `PARTIAL`：合同来源、稳定性和版本都可审计，但缺少部分操作或串行队列、核心保护、回滚等安全保证；省略 `pluginId` 时只做 Host 级能力观察，即使合同完整也不会针对具体插件返回 `SUPPORTED`；
- `UNAVAILABLE`：没有可读 inventory，或合同没有被官方 DSH Host 标记为权威、稳定并带可审计版本。当前普通 rc.6 Host 通常应落在这里；
- `MANUAL_REVIEW`：目标是核心/Debug、runtime-only、祖先禁用、动态 `!!js`、已经禁用、ID 歧义或其他需要人工判断的条目。

最小可审计合同必须同时包含：`source=dsh-host`（或 `official=true`）、
`stable=true`、非空 `version`、`operations` 中的
`entry.update`/`entry.dispose`/`entry.refresh`，以及
`serialQueue=true`、`coreProtection=true`、`rollback=true`。缺少操作或安全字段
是 `PARTIAL`；缺少权威来源、稳定标记或版本则是 `UNAVAILABLE`。

报告固定带有 `executionAttempted=false`、`executionVerified=false`、`actionsExecuted=[]`、`targetMutated=false` 和 `actualHotSwap=false`。它不会调用 `entry.update()`、`dispose()`、`refresh()`、`_dispose()`，不会清理 ESM/CJS 缓存，不会监听 `package.json`，不会执行 npm/pnpm/shell，不会改写 `cordis.patch.yml`，也不会开放无鉴权 POST。

当前 DSH runtime 可能已经加载官方 `@deepseek-ai/cordis-plugin-hmr`，但“观察到 HMR”不等于 Debug 获得了插件修改权；没有稳定生命周期合同时，报告仍返回 `UNAVAILABLE`。这正是本工具与 GitHub 上两个 `dsh-hotswap` 项目的边界：吸收保护名单、ancestor/runtime-only/动态表达式检查和 fail-closed 报告形状，不吸收内部 `_dispose`/`refresh`、缓存驱逐、自动安装卸载或 Profile watcher。

## Agent 报告（`dsh_agent_report`）

本包吸收了 [dsh-whale-report](https://github.com/SenmuuuuW/dsh-whale-report) 的确定性报告产品形状：把 Session、Token、模型/Provider、Tool Call、失败、重试、风险和费用估算整理成能读懂的中文报告。当前实现位于 `src/agent-report.js` 和 `src/tool-adapter.js`，由本地代码统计和渲染，生成报告消耗 0 token。

### 数据来源、输入和输出

工具不会自己寻找目录或读取 Profile 文件。它从 DSH Host 注入的数据服务读取，优先使用同时提供 `listSessions`/`readSession` 的 `sessionQuery`；没有该服务时才回退到 `ctx.sessions`，并在报告中标明“仅当前内存会话”。两者都不可用时返回 `UNAVAILABLE`。

调用参数只有报告区间：

```text
dsh_agent_report(preset="weekly")
dsh_agent_report(preset="daily")
dsh_agent_report(preset="custom", from="2026-08-01T00:00:00Z", to="2026-08-17T00:00:00Z")
```

| 输入 | 含义 |
| --- | --- |
| `preset` | `daily`、`24h`、`weekly`、`monthly`、`yearly` 或 `custom`；省略时为 `weekly` |
| `from` / `to` | 只有 `custom` 必须提供有效 ISO 时间，并且 `to` 必须晚于 `from` |

ToolRuntime 对外返回的是一个字符串（`output.schema.type=string`），内容是 Markdown 报告。内部结果还带有 `schemaVersion=1`、`status`、`sourceKind`、时间范围、覆盖统计、汇总和费用对象，便于测试或 Host 适配层审阅。报告会展示：

- Session、subagent Session、turn、step、user/assistant message 和事件数量；
- input/output/cache-read/cache-write/reasoning Token，以及按 model/provider 分组的用量；
- Tool Call 总数、工具名排行、Tool error、turn failure、abort、interruption 和 retry burst；
- 危险操作的红/黄级别与类型、疑似密钥/令牌的类型、费用最高的 Session；
- 数据源、列出/读取/使用了多少 Session 和事件，以及是否为 `PARTIAL` 覆盖。

### 有界扫描、费用和风险边界

支持 `daily`、`24h`、`weekly`、`monthly`、`yearly`、`custom`。扫描固定有界：最多列出/选择 500 个 Session；单个 Session 最多读取 100,000 条事件；总计最多使用 1,000,000 条事件。读取失败、列表或事件达到上限时返回 `PARTIAL`，并在报告中写明覆盖不完整；没有可读 Session 服务或源读取失败时返回 `UNAVAILABLE`。这类报告不能被当成完整账单或完整历史。

费用是本地内置价格的估算，币种标为 CNY，未知模型按 flash 档估算；它不是 DSH/模型供应商账单、余额或结算结果，不联网抓价格，也不请求余额。报告中的费用必须理解为“内置估算价，非账单”。

工具只读：不调用模型，不执行命令、shell 或 PowerShell，不写回 Session，不修改 Profile/Workspace，不读取凭据，不上传数据。报告不输出原始命令、Tool 错误正文、密钥原文或完整 Session ID，只保留脱敏短 ID 和风险类型。`rm -rf`、删库、关机/重启、格式化磁盘、force push 等内容如果已经存在于 Session 事件文本中，只会被正则识别为风险线索；这些字符串不会传给 `child_process`、shell 或任何执行器，识别结果也不证明 Debug 插件执行过命令。

### 脱敏 JSON 离线报告

真实 Host 没有历史 Session 时，可以把经过人工脱敏的、明确指定的 JSON 文件交给本地报告入口：

```powershell
.\Debug-DSH.ps1 `
  -Action agent-report `
  -InputPath .\tools\fixtures\agent-report-document.json `
  -Preset weekly
```

输入必须是 `schemaVersion: 1` 的版本化文档；入口只读取这个明确文件，不扫描 `DSH_HOME`、Profile 或目录，不联网，不执行其中的命令，并拒绝符号链接输入。示例格式见 [`tools/fixtures/agent-report-document.json`](tools/fixtures/agent-report-document.json)。不要把 `.env`、`.credentials*`、密钥、私钥、证书或未脱敏的 Session 文件交给它；它是离线算法复现入口，不是凭据扫描器。报告默认输出到 stdout，不输出原始 Session ID、命令、错误正文或 Secret 原文。

离线 JSON 报告可以证明报告算法、Token replacement 和脱敏边界可用，但不能替代真实 DSH 的有数据 SessionQuery 验证。缓存写入 Token 会被显示；由于供应商计费规则不统一，当前内置费用估算不把缓存写入自动当成可计费价格项。

### 对 `dsh-whale-report` 的吸收边界

吸收的是确定性统计、可读 Markdown 报告和“风险/异常/成本都要有覆盖说明”的产品形状，不是把上游项目作为运行时依赖。没有复制或启用以下能力：余额探针、凭据/密钥读取、`DEEPSEEK_API_KEY` 或其他秘密读取、联网请求或联网抓价格、完整 Web UI、外部运行时依赖，以及 Unix-only 的 `rm -rf lib` 构建脚本。Debug 自己的构建脚本使用 Node 文件 API；报告中的危险命令文本是惰性输入，不会执行。

## 已验证的证据层级与 rc.6 限制

下面三层证据必须分开看，不能把其中一层的绿色结果扩大解释成另外两层已经通过：

| 证据层级 | 已证明什么 | 没有证明什么 |
| --- | --- | --- |
| fake/fixture/loopback | 合成 Session、Node 测试、PowerShell fixture 和 fake/loopback runtime 回归了报告聚合、边界、脱敏、Crash Guard 与 supervisor 分支 | 没有证明真实 DSH Web、真实 Host inventory 或真实业务历史存在 |
| 真实 Host 注册与 ToolRuntime | 在临时隔离目录用 pinned `@deepseek-ai/dsh@0.1.0-rc.6` 启动真实 Web：`http://127.0.0.1:31989/` 和 `http://127.0.0.1:31990/` 返回 HTTP 200，`webIsDsh=true`；真实 API `host.describe`、`session.list`、`pluginInventory/list` 可调用。`pluginInventory/list` 观察到 `entryCount=134`、`failedCount=0`，其中 `dsh-plugin-debug` 为 `enabled=true`、`fiberPhase=active`。临时 ToolRuntime 探针还确认 `plugin_check`、`plugin_hotswap_check`、`dsh_agent_report` 都已注册并可执行，三者均 `isError=false` | 只证明真实 Host 能加载、注册并 dispatch 工具；探针包只存在于隔离 Profile，未进入仓库或发行包，也不等于已经读到真实业务 Session |
| 真实业务 Session 历史 | 当前没有通过这一层：隔离 Profile 的 `session.list` 返回空列表，所以 `dsh_agent_report` 的真实 dispatch 结果是 `PASS`、0 个 Session、0 条事件、0 Token、`¥0.0000`，并确认没有执行命令或修改数据 | 没有验证有数据 Session 的真实 Token、费用、Tool Call、风险或异常统计；不能把空历史的 PASS 当成业务历史证明 |

上述真实 Host 检查使用的是临时隔离 Profile，不访问真实用户 Profile 或凭据。另一个独立的外部限制是：在同一个 pinned rc.6 隔离环境中直接调用 `session.create` 会失败，错误为 `agent-preset-invalid`，核心原因是 `preset "standard" failed to mount: prompt section "deployment:persona" is already registered`；使用 `minimal` preset 也出现同类重复注册错误。这是 rc.6 的 agent-preset/deployment:persona 装载问题，不是 `dsh_agent_report` 造成的。因而当前只能声称真实 Web、inventory、工具注册和空历史 dispatch 已验证，不能声称已经创建并读取真实业务 Session。

真实 ToolRuntime 的三项结果还应按各自语义阅读：`plugin_check(action="schema")` 成功返回检查 schema；`plugin_hotswap_check` 成功返回 `verdict=UNAVAILABLE`、`execution=NOT_ATTEMPTED`、`actualHotSwap=false`，说明安全门禁没有执行热切换；`dsh_agent_report` 成功返回合法空报告，说明注册和调用链可用，但不增加业务历史数据。

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

任务守护是包内的运行时观察器。默认 `policy=auto` 时，在冷却窗口内最多给同一 Session 发送一次脱敏指导；`policy=report` 只记录发现，不发送指导。它使用 Tool 名称和经过敏感字段替换的参数形状生成 SHA-256 指纹，状态接口为 `/api/dsh-plugin-debug/guardian/status`。内存中的最近事件窗口、每条事件元数据和磁盘事件日志均有界：默认保留当前 `events.jsonl` 加两个轮转文件，每个文件最多 256 KiB；可通过 `eventLogMaxBytes`（1 KiB–4 MiB）和 `eventLogMaxFiles`（2–10）调整。轮转只处理 Debug 自己的 `guardian/events.jsonl*` 文件，不读取或清理其他 DSH 数据。状态和事件报告不会返回原始 Session ID、原始 Tool 参数或正文；长期运行时仍不要把本地日志提交或上传。如果 Host 没有 `agents` 服务或对应事件服务，插件仍可启动但守护保持空闲。

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

先记住两个边界：`Verify-Publication.ps1` 必须在 `npm ci` 之前运行；安装依赖后不要在同一棵树上再次运行它。安装后的 `node_modules` 只用于测试，真正的 `npm pack` 要从排除 `node_modules` 的 pack-only staging 目录运行。历史 `RELEASE-MANIFEST.json` 中的文件数只属于旧的已验证提交，不能直接套用到未提交候选。

1. 在 `src/`、`tools/`、入口脚本中修改源码，同时添加对应 Node/PowerShell 回归测试；每项新功能至少要有一个正常场景和一个拒绝/失败场景。
2. 不手工编辑 `lib/` 和 `bundle-manifest.json`，由 `npm run check` 重新构建并校验。
3. 按语义化版本（SemVer）更新 `package.json`，同步 `package-lock.json`；README、变更说明和实际行为必须一致。
4. 运行 `npm test`、`npm run check`、`npm run check:standalone`、`npm run check:integration`、`Test-DSHStandalone.ps1` 及相关工具测试。
5. `npm run check` 会重建 `lib` 和 `bundle-manifest.json`；先比较生成的 `src`/`lib` 文件哈希，再从不含依赖目录的 pack-only staging 运行 `scripts/Verify-Publication.ps1` 和 `npm pack --dry-run --json --ignore-scripts`，把实际文件数量同步到 `RELEASE-MANIFEST.json` 和 `SOURCE-SNAPSHOT.md`。
6. 检查 `git diff --check`、敏感文件和待提交内容；先做本地可审阅的 candidate source commit 并 push，再读取远端提交哈希，从该远端提交创建 fresh clone（全新克隆）重跑测试。
7. 只有 fresh clone 通过后，才用单独的 evidence commit 更新发布清单的 `publishedCommit`、UTC 验证时间和 `status`，然后再 push evidence commit；如果仍是候选状态，不要在 README 中宣称正式发布。

不要提交 `node_modules`、`.dsh`、`.codex`、Profile state、logs、coverage、credentials、临时 fake runtime 或测试输出。新功能必须继续保持默认离线、仅元数据（metadata-only）和失败即停止（fail-closed）安全契约；如果需要更高权限、联网或自动执行，先增加独立的安全评审和回归测试。特别是插件热切换必须作为独立 opt-in 功能，不能把第三方仓库的内部生命周期调用直接并入默认 Debug。

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
