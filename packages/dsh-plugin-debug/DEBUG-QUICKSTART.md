# DSH Debug Plugin 快速开始

这份文档只解决五件事：安装、启动、导出诊断、生成 Agent 报告、更新。完整能力说明见 [`README.zh-CN.md`](README.zh-CN.md)。

## 先记住 7 件事

- 这是本地 DSH 调试插件，不是插件商店；它不会搜索、安装或调用 `dsh-plugin-store`。
- 想保证本次启动过程不自动联网，启动命令必须带 `-NoInstall`，并且本机已经准备好 DSH runtime 或 `PATH` 中的 `dsh` 命令。
- 如果缺少 runtime 且没有带 `-NoInstall`，启动器会按照包内固定的 `tools/runtime/package-lock.json` 执行一次 `npm ci`；这一步可能联网。
- 当前版本不提供默认热切换。修改源码后必须停止旧 DSH，再重新安装并启动；不会调用未经 DSH 官方确认的 `_dispose`、`refresh`，不会监听 `package.json` 自动安装/卸载依赖。
- `npm test`、`Test-DSHStandalone.ps1`、`plugin_check` 和 fixture 主要证明离线、静态或合成契约通过；它们不等于真实 DSH Web、Host API、浏览器页面或生产任务已经验证。
- `dsh_agent_report` 是 DSH Host 注册的 Tool，不是可以直接粘贴到 PowerShell 的命令；它只在 Host 提供可读 Session 数据时报告真实数据。
- `Start-DSH-Debug.ps1` 默认启用 Crash Guard 和有界 Runtime Supervisor；故障恢复时可能写入 Guard 状态、隔离已明确归因的第三方插件并最多受控重启一次。只想生成离线报告时不要启动它。

## 1. 准备环境

需要：

- Windows；
- PowerShell 7（命令名是 `pwsh`）；
- Node.js 22 或更高版本；
- 本机已经安装好的 DSH runtime，或者 `PATH` 中可以执行 `dsh`。

如果本机还没有固定版本 runtime，只有在你明确同意联网时才执行下面这条命令：

```powershell
Set-Location .\packages\dsh-plugin-debug
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
```

这条命令只准备包内锁定的 DSH runtime，不安装其他 DSH 插件。`tools/runtime/node_modules` 属于本地/CI 测试准备，不属于 GitHub 源码或 npm 发布包。

## 2. 启动 Debug 插件

从仓库根目录执行：

```powershell
Set-Location .\packages\dsh-plugin-debug
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
```

启动完成后，手动打开：

```text
http://127.0.0.1:3081
```

`-NoInstall` 只表示缺少 runtime 时不自动执行 npm 安装；它不要求 DSH 已经运行。如果本机没有 runtime，命令会直接提示缺少环境，不会偷偷下载。

如果你已经明确同意由启动器准备缺少的 runtime，可以省略 `-NoInstall`：

```powershell
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoBrowser
```

## 3. 导出诊断报告

DSH 正在运行时，执行：

```powershell
.\Debug-DSH.ps1 -Action incident-capture -Profile debug -Port 3081 -IncidentPath .\state\debug-incident.json
```

报告会写入：

```text
.\state\debug-incident.json
```

如果 DSH 没有启动，只检查本地文件和状态，可以加 `-SkipApi`：

```powershell
.\Debug-DSH.ps1 -Action incident-capture -Profile debug -Port 3081 -SkipApi -IncidentPath .\state\debug-incident.json
```

报告是有界诊断证据，不是完整日志转储，也不会执行 Tool 或发送模型提示。分享前请先打开检查，删除机器名、本地路径、Session 标识等环境信息；不要直接上传整个 `state`、`logs`、Profile 或工作区目录。

## 4. 生成 Agent 报告

### A. 在真实 DSH 中生成

启动 DSH 后，让 DSH Agent/Host 调用这个 Tool（下面是 Tool 参数示例，不是 PowerShell 命令）：

```text
dsh_agent_report(preset="weekly")
```

可选区间是 `daily`、`24h`、`weekly`、`monthly`、`yearly`；`custom` 需要同时提供 ISO 格式的 `from` 和 `to`。报告会统计 Session、回合、Token、缓存命中/写入、Tool Call、失败、重复重试、危险命令文字线索和疑似密钥类型，并给出本地内置费用估算。

`UNAVAILABLE` 表示 Host 没有可读的 Session 服务；`0 Session` 表示服务可读但所选时间范围为空；`PARTIAL` 表示有会话读取失败或触及有界上限。费用是估算，不是服务商账单；缓存写入 Token 会显示，但当前没有按未知供应商规则计入费用公式。

### B. 没有真实 Session 时，用明确提供的脱敏 JSON 离线生成

这条路径只读取你明确指定的一个 JSON 文件，不会扫描 Profile、`DSH_HOME`、`.env` 或凭据目录，不联网，不执行 JSON 里的命令。输入必须是版本为 `schemaVersion: 1` 的脱敏 Session 文档，示例见 [`tools/fixtures/agent-report-document.json`](tools/fixtures/agent-report-document.json)。

```powershell
.\Debug-DSH.ps1 `
  -Action agent-report `
  -InputPath .\tools\fixtures\agent-report-document.json `
  -Preset weekly
```

也可以直接调用 Node 入口：

```powershell
node .\tools\Generate-DSHAgentReport.mjs `
  --input .\tools\fixtures\agent-report-document.json `
  --preset weekly
```

报告默认输出到屏幕（stdout）；它不会把原始 Session ID、命令、错误正文或 Secret 原文写入报告。请不要把 `.env`、`.credentials*`、密钥、私钥、证书或未脱敏的 Session 文件作为输入；这条入口是“明确文件 + 已脱敏”的离线复现工具，不是凭据扫描器。

注意：离线 JSON 能证明报告算法和输入协议可用，不能替代真实 DSH SessionQuery 的有数据验证。真实环境没有历史时，`dsh_agent_report` 返回 `0 Session` 是诚实结果。

## 4.5. 判断要不要吸收 hotswap 插件

先对候选仓库做离线源码预检；这一步不会安装、导入、运行或修改候选：

```powershell
.\tools\Preflight-DSHHotswap.ps1 -Path C:\path\to\candidate
```

看到 `MANUAL_REVIEW` 时，先阅读 finding 中列出的文件，再决定是否人工审查。预检不是兼容性认证，也不是漏洞利用证明；它只帮助你提前发现 shell 执行、私有生命周期 API、无鉴权控制面、非原子 patch 以及缺少回滚/队列/核心保护/CI 等问题。

## 5. 更新插件

更新不是热切换。先停止旧实例，再强制覆盖已安装的本地 bundle：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoInstall -NoBrowser
```

`-ForcePluginInstall` 只表示下次启动时重新安装当前 bundle，不表示运行中的插件已经被热替换。

## 如何看结果

- `PASS`：这一项检查通过；
- `UNAVAILABLE`：本机缺少对应的真实 DSH、Host API、浏览器或外部服务；
- `PARTIAL` / `WARN`：只有部分证据，不能下完整结论；
- `FAIL`：检查本身失败，需要查看错误信息。

特别注意：生成了 JSON 报告、`npm test` 通过、CI 变绿，都不能单独证明生产 DSH 已经恢复。要声称“真实 DSH 已验证”，还需要真实 Web ready、真实 Host API 和实际页面或任务交互证据。
