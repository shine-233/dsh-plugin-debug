# DSH Debug Plugin 快速开始

这份文档只解决四件事：安装、启动、导出诊断、更新。完整能力说明见 [`README.zh-CN.md`](README.zh-CN.md)。

## 先记住 5 件事

- 这是本地 DSH 调试插件，不是插件商店；它不会搜索、安装或调用 `dsh-plugin-store`。
- 想保证本次启动过程不自动联网，启动命令必须带 `-NoInstall`，并且本机已经准备好 DSH runtime 或 `PATH` 中的 `dsh` 命令。
- 如果缺少 runtime 且没有带 `-NoInstall`，启动器会按照包内固定的 `tools/runtime/package-lock.json` 执行一次 `npm ci`；这一步可能联网。
- 当前版本不提供默认热切换。修改源码后必须停止旧 DSH，再重新安装并启动；不会调用未经 DSH 官方确认的 `_dispose`、`refresh`，不会监听 `package.json` 自动安装/卸载依赖。
- `npm test`、`Test-DSHStandalone.ps1`、`plugin_check` 和 fixture 主要证明离线、静态或合成契约通过；它们不等于真实 DSH Web、Host API、浏览器页面或生产任务已经验证。

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

## 4. 更新插件

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
