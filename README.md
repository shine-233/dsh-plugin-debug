<h1 align="center">dsh-plugin-debug</h1>

<p align="center">
DSH（DeepSeek Harness）调试插件：崩溃隔离、事故取证、Trace 分析、快照恢复、任务守护。
</p>

<div align="center">

[![CI](https://github.com/shine-233/dsh-plugin-debug/actions/workflows/ci.yml/badge.svg)][ci]
[![CodeQL](https://github.com/shine-233/dsh-plugin-debug/actions/workflows/codeql.yml/badge.svg)][codeql]
[![License](https://img.shields.io/badge/license-MIT-green.svg)][license]
[![Version](https://img.shields.io/github/v/tag/shine-233/dsh-plugin-debug?label=v0.8.5)][tag]
![DSH](https://img.shields.io/badge/DSH-0.1.1--rc.2-blue)
![Node](https://img.shields.io/badge/node-%E2%89%A522-brightgreen)

[快速开始](#快速开始) · [兼容版本](#兼容版本) · [它能做什么](#它能做什么) · [验证到什么程度](#验证到什么程度) · [文档](#文档)

</div>

## 这是什么

写 DSH 插件或折腾 DSH 环境时，出问题往往不知道从哪查：插件装完不生效、页面白屏、任务跑飞、Profile 改坏。这个包把排查要用的东西凑齐了：启动失败自动隔离可疑插件（最多重启一次，绝不无限自愈）、事故现场打包取证、Session 脱敏报告、known-good 检查点回滚，外加一个只观察不干预的任务守护。

单包发布在 `packages/dsh-plugin-debug`，MIT，不发 npm。面向 Windows，建议 pwsh 7 + Node 22 以上。

## 快速开始

装好 Node.js 22+，在 PowerShell 进仓库根目录：

```powershell
Set-Location .\packages\dsh-plugin-debug
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
```

看到 JSON 输出后打开 `http://127.0.0.1:3081`。`-NoInstall` 表示不联网，要求本机已有 DSH runtime；没有就去掉它，启动器会按 lockfile 精确安装 pinned runtime。

不想启动、只想先验货：

```powershell
npm test
.\Test-DSHStandalone.ps1
```

更新已装到 Profile 的插件：先用 `.\tools\Stop-DSH.ps1` 停旧实例，再加 `-ForcePluginInstall` 重启。

报告状态怎么读：`PASS` 通过；`UNAVAILABLE` 是本机没有对应服务，不是错误；`PARTIAL` 和 `WARN` 表示只有部分证据；`FAIL` 才是失败。

## 兼容版本

| | 版本 |
|---|---|
| 插件 | 0.8.5 |
| pinned runtime | `@deepseek-ai/dsh` 0.1.1-rc.2 |
| peer 兼容范围 | `dsh-tools >=0.1.0-rc.6 <0.2.0` |

0.8.5 相对 0.8.4 的主要变化：适配 DSH 0.1.1-rc.2，重建 runtime lockfile（516 个锁定条目，补齐上游改为 peerDependencies 声明的 29 个内部包）。详见 [CHANGELOG](CHANGELOG.md)。

## 它能做什么

**查问题**：插件健康检查、事故取证打包、客户端诊断时间线、Trace 循环/递归分析、两份诊断报告对比、依赖图检查。

**救现场**：Crash Guard 启动隔离、Profile/Workspace 快照与 known-good 回滚、受限自修复（前后哈希校验，文件被改过就拒绝覆盖）、只读的第三方插件二分计划。

**看清楚**：鼠标来源追踪、Agent/Session 脱敏报告（Token、工具调用、风险、内置估算费用）、热切换能力探测（只探测合同，从不执行切换）。

**管住任务**：observer-only 任务守护，发现重复 Tool Call 或过深的 Agent/Workflow 递归时给提示，不终止任务、不杀进程、不禁插件。

注册到 Host ToolRuntime 的四个工具：`plugin_check`、`plugin_hotswap_check`、`plugin_hotswap_preflight`、`dsh_agent_report`。

## 验证到什么程度

v0.8.5 在真实环境验证过：GitHub fresh clone 重跑全部测试（95/95），用 pinned runtime 启动真实 DSH 0.1.1-rc.2，Web 页面识别为 DSH、`host.describe` 正常、140 条 inventory 中观察到本插件 active。发布边界检查 108 文件全过。

没验证过的也直说：成功模型响应、真实 Token 账单、模型生成的 Tool Call、生产环境第三方安装、跨平台运行。想自己复核一遍：

```powershell
pwsh -File .\tools\Test-DSHCompatibility.ps1 -ConfirmRealDsh -StartPinnedRuntime -RuntimeRoot .\tools\runtime
```

它会在临时 `DSH_HOME`、Profile 和端口里启动真实 runtime，结束时只清理自己启动的东西。

## 文档

- [`packages/dsh-plugin-debug/DEBUG-QUICKSTART.md`](packages/dsh-plugin-debug/DEBUG-QUICKSTART.md)：安装、启动、导出诊断、更新的分步说明
- [`packages/dsh-plugin-debug/README.zh-CN.md`](packages/dsh-plugin-debug/README.zh-CN.md)：每个动作的输入输出和安全边界
- [`CHANGELOG.md`](CHANGELOG.md) / [`ROADMAP.md`](ROADMAP.md)：变化记录和维护路线
- [`PUBLISHING.md`](PUBLISHING.md)：发版流程与门禁
- 想系统学 DSH，去 [`shine-233/deepseek-harness-study`](https://github.com/shine-233/deepseek-harness-study)

## 安全边界

默认只收集元数据：Tool 参数、结果正文、Cookie、密钥、`.env` 内容一律不落盘，不上传日志，不访问插件商店。Guardian 只读事件、发提示。会动手的部分（Crash Guard、修复、恢复）各有闸门：核心包不动、敏感文件不碰、回滚前校验哈希、最多一次受控重启。Host API 默认只接受 loopback，远端地址必须显式白名单。

逐条细则见包内 README 的安全边界一节。

## 本地开发

```powershell
# 包目录
npm ci --ignore-scripts
npm test        # 95 项离线回归
npm run check   # 构建 + 生成物一致性 + 语法 + workflow pin + 测试

# 仓库根目录
.\scripts\Verify-Publication.ps1   # 发布边界检查
```

大部分回归不需要真实 DSH；需要本机服务的项会诚实返回 `UNAVAILABLE`，不会拿静态 fixture 冒充真实验证。升级 pinned runtime 时同步重建 `tools/runtime/package-lock.json`、`Install-DSH-Agents.ps1` 固定清单和 SBOM，再重跑全部门禁。

## License

[MIT](LICENSE) © shine-233

[ci]: https://github.com/shine-233/dsh-plugin-debug/actions/workflows/ci.yml
[codeql]: https://github.com/shine-233/dsh-plugin-debug/actions/workflows/codeql.yml
[license]: LICENSE
[tag]: https://github.com/shine-233/dsh-plugin-debug/releases
