# DSH Debug Plugin 快速开始

`dsh-plugin-debug` 是本地 DSH 调试工具的唯一运行时插件，包含页面来源追踪、客户端诊断、插件健康检查、事故取证、Trace 分析、Crash Guard、known-good 快照、受限恢复和修复规划。本包没有插件商店能力，也不会调用 `dsh-plugin-store`。

## 安装这个插件

在包目录中使用固定版本的本地 DSH runtime：

```powershell
node .\tools\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js `
  plugin --profile debug add . --offline
```

安装完成后重启 DSH 并打开 Web 页面。调试设置面板会出现在正常设置入口中。可以保持面板关闭；除非显式配置 Tool Policy，否则客户端不会改变工具策略。

## Windows 一键入口

可以双击 `Start-DSH-Debug.vbs`，也可以运行：

```powershell
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081
```

这个入口会启动固定版本 runtime，必要时离线安装本地 bundle，启用有界 Crash Guard/监督器，等待 loopback Web ready；除非传入 `-NoBrowser`，否则最后打开浏览器。

## 只读诊断

统一入口保留原 provenance 工具的完整诊断动作：

```powershell
.\Debug-DSH.ps1 -Action doctor -Profile debug -SkipApi
.\Debug-DSH.ps1 -Action plugin-health -Profile debug -SkipApi
.\Debug-DSH.ps1 -Action incident-capture -Profile debug -SkipApi
.\Debug-DSH.ps1 -Action trace-autopsy -InputPath .\tools\fixtures\tool-call-trace.json
```

恢复和修复动作仍然有界，并且必须显式调用。诊断报告只是证据，不代表生产 DSH 已经修复。
