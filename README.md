# dsh-plugin-debug（DSH 调试插件）

一个面向 [DeepSeek Harness（DSH）](https://github.com/shine-233/deepseek-harness-study) 的单包开源调试插件：把宿主检测、插件健康检查、崩溃隔离（Crash Guard）、事故取证、Trace 分析、快照恢复、受限自修复和任务守护合并成一个可审阅、可测试的包。

- 公开运行时包只有一个：`packages/dsh-plugin-debug`（MIT，不发布到 npm registry）。
- 面向 Windows；建议 PowerShell 7（`pwsh`）+ Node.js ≥ 22。
- 默认离线、仅收集脱敏元数据、失败即停止（fail-closed）。

## 兼容版本

| 组件 | 版本 | 说明 |
|------|------|------|
| 本插件 | `0.8.5` | 当前工作树版本 |
| pinned runtime | `@deepseek-ai/dsh@0.1.1-rc.2` | 启动器按 lockfile 精确安装 |
| peer 兼容范围 | `@deepseek-ai/dsh-tools >=0.1.0-rc.6 <0.2.0` | rc.6 及以上均可 |

`0.8.5` 已完成对 DSH `0.1.1-rc.2` 的适配：pinned runtime lockfile 全量重建（516 个锁定条目，含上游新改为 peerDependencies 的内部包闭包），并通过了 lockfile 校验、scratch 目录完整 `npm ci` 实装、`dsh --version` 冒烟和 95/95 Node 测试。上一个完成 GitHub source release 全套证据闭环的版本是 `0.8.4`（源码提交 `687dbaba3897a50ff2c797049ad9755eb76576d5`）；按 [`PUBLISHING.md`](PUBLISHING.md) 重跑 fresh-clone 门禁后即可为 `0.8.5` 打 tag。

**仍然没有证明的事**：真实有数据的成功模型响应、真实 Token/供应商账单、模型生成的 Tool Call、生产环境第三方插件安装、生产热切换和跨平台兼容。不要把离线 fixture 或工具注册证据扩大成这些结论。

## 快速开始

不懂代码也能启动，只做三步：

1. 安装 Node.js 22 或更高版本，在 PowerShell 进入仓库根目录。
2. 复制下面两行命令。想保证启动过程不自动联网，加 `-NoInstall`（需要本机已有 DSH runtime，缺了会直接提示，不会偷偷下载）：

   ```powershell
   Set-Location .\packages\dsh-plugin-debug
   .\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -NoInstall -NoBrowser
   ```

3. 看到 JSON 或窗口后，打开 `http://127.0.0.1:3081`。

只想先验证文件和脚本本身，不启动 DSH：

```powershell
npm test
.\Test-DSHStandalone.ps1
```

更新已安装到 Profile 的本地插件时，先停旧实例再强制覆盖：

```powershell
.\tools\Stop-DSH.ps1 -Profile debug -Port 3081
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081 -ForcePluginInstall -NoInstall -NoBrowser
```

也可以用 DSH CLI 离线安装本地 bundle：`dsh plugin --profile debug add . --offline`。

报告状态含义：`PASS` 通过；`UNAVAILABLE` 本机没有对应服务（不是失败）；`PARTIAL`/`WARN` 只有部分证据；只有 `FAIL` 才是检查失败。生成报告成功 ≠ DSH 已恢复。

## 它能做什么

| 能力方向 | 行为要点 | 主要入口 |
|----------|----------|----------|
| 来源追踪（Provenance） | Web 客户端桥接、鼠标来源、Slot/Module 证据 | `lib/client.js`、`DSH-Provenance.ps1` |
| 宿主诊断 | 上下文、插件健康、Session 健康、安全审计、资源压力 | `tools/DSH-ProvenanceSuite.ps1`、`tools/Get-DSH-PluginHealth.ps1` |
| 事故取证 | 多层组件、启动回执、指针证据、Trace、完整性哈希 | `tools/DSH-Incident.ps1` |
| 客户端时间线 | 有界 breadcrumb 环形缓冲、去重、脱敏导出 | `__DSH_PLUGIN_DEBUG__.getDiagnosticBreadcrumbs()` |
| 崩溃防护 | 启动失败识别、安全候选隔离、一次受控重启 | `tools/Start-DSH.ps1`、`tools/DSH-Guard.psm1` |
| 快照与恢复 | Profile/Workspace 快照、known-good 检查点、会话分支 | `tools/DSH-Recovery.psm1`、`tools/DSH-KnownGood.psm1` |
| 受限修复 | 受控计划、receipt、前后哈希校验、冲突即回滚拒绝 | `tools/DSH-Repair.psm1`、`tools/DSH-SelfRepair.ps1` |
| Trace 分析 | 仅元数据 trace、循环/递归检测、autopsy、复现导出 | `Debug-DSH.ps1 -Action trace-*` |
| 插件二分 | 只读生成安全的第三方候选试验顺序 | `Debug-DSH.ps1 -Action plugin-bisect-plan` |
| 报告对比 | 两份脱敏报告的元数据 diff，敏感字段转人工复核 | `Debug-DSH.ps1 -Action diagnostics-diff` |
| 插件预检 | 离线扫描静态 `inject` 与 `ctx.*` 服务依赖 | `Debug-DSH.ps1 -Action plugin-preflight` |
| 仓库健康检查 | 离线检查清单协议、patch 形态、构建陷阱 | `plugin_check` 工具 |
| 热切换探测 | 只读探测 Host 生命周期合同，绝不执行切换 | `plugin_hotswap_check` / `plugin_hotswap_preflight` |
| Agent 报告 | 从 Session 生成脱敏 Token/工具调用/风险/估算费用报告 | `dsh_agent_report` 工具 |
| 任务守护 | 观察式检测重复 Tool Call 与过深递归，只提示不终止 | `lib/task-guardian.js` |
| 一键启动 | PowerShell/CMD/VBS 入口、端口冲突隔离、启动回执 | `Start-DSH-Debug.*` |

注册到 Host ToolRuntime 的四个工具：`plugin_check`、`plugin_hotswap_check`、`plugin_hotswap_preflight`、`dsh_agent_report`。

## 证据分层

截至 2026-08-22，证据分四层，不能合并成一个"全部可用"的结论：

| 证据层 | 当前结论 |
|--------|----------|
| 源码、Node/PowerShell 回归、脱敏 fixture | 证明单包实现、边界和 fail-closed 契约；不是生产 DSH 证明 |
| fake/loopback 监督器与启动回归 | 证明默认启动、可归因故障隔离和不可归因故障 fail-closed 的本地流程 |
| 隔离的真实 `@deepseek-ai/dsh@0.1.0-rc.6` | 真实 Web/Host 可启动，inventory 可见本插件 active，三个工具通过真实 ToolRuntime 注册与 dispatch |
| 尚未证明 | 成功模型响应、真实账单、模型 Tool Call、生产第三方安装、生产 hotswap、跨平台兼容 |

`0.8.5` 对 `0.1.1-rc.2` 的适配目前覆盖第一层（lockfile 闭包校验 + 完整安装 + CLI 冒烟 + 回归测试）；真实 Host/Web 复核可用下面的兼容性脚本自行确认。

真实 DSH 只在明确手动确认时检查：

```powershell
pwsh -File .\tools\Test-DSHCompatibility.ps1 -ConfirmRealDsh -BaseUrl http://127.0.0.1:3080
# 或让它用 pinned runtime 在临时 DSH_HOME/Profile/端口中启动：
pwsh -File .\tools\Test-DSHCompatibility.ps1 -ConfirmRealDsh -StartPinnedRuntime -RuntimeRoot .\tools\runtime
```

没有确认、服务不可用或插件未出现在真实 inventory 中都不会记为 `PASS`；该脚本不用 fake fixture、不调用模型、不动已有实例。

## 文档地图

| 想做什么 | 看哪里 |
|----------|--------|
| 傻瓜式安装/启动/导出诊断/更新 | [`packages/dsh-plugin-debug/DEBUG-QUICKSTART.md`](packages/dsh-plugin-debug/DEBUG-QUICKSTART.md) |
| 逐项了解动作、输入和安全边界 | [`packages/dsh-plugin-debug/README.zh-CN.md`](packages/dsh-plugin-debug/README.zh-CN.md) |
| 功能变化记录 | [`CHANGELOG.md`](CHANGELOG.md) |
| 维护路线 | [`ROADMAP.md`](ROADMAP.md) |
| 发布流程与门禁 | [`PUBLISHING.md`](PUBLISHING.md)、[`PUBLICATION-CHECKLIST.md`](PUBLICATION-CHECKLIST.md)、[`RELEASE-MANIFEST.json`](RELEASE-MANIFEST.json) |
| 公开边界与迁移记录 | [`SOURCE-SNAPSHOT.md`](SOURCE-SNAPSHOT.md)、[`MIGRATION-MANIFEST.md`](MIGRATION-MANIFEST.md) |
| 同类项目比较 | [`RESEARCH-ECOSYSTEM.md`](RESEARCH-ECOSYSTEM.md) |
| 系统学习 DSH | [`shine-233/deepseek-harness-study`](https://github.com/shine-233/deepseek-harness-study) |

## 安全边界

- **默认只收集元数据**：不保存 Tool 参数、Tool 结果正文、会话正文、Cookie、Authorization、API key、`.env` 内容或完整工作目录；不上传日志，不连 Langfuse/OpenTelemetry，不访问插件商店。
- **Guardian 是 observer-only**：只读 Host 已发出的生命周期事件，生成指纹和短提示；不终止任务、不杀进程、不重启 Host、不禁用插件、不改 Profile。
- **整个包不是无副作用工具**：Crash Guard/Runtime Supervisor 可能停止已确认的 DSH 子进程、写入可逆 Guard state/patch，最多一次受控重启；第二次失败进入 `degraded`。底层 `Start-DSH.ps1` 默认关闭该处置能力，公开 Debug 启动器才显式开启。
- **自动隔离范围极窄**：只有能被当前 manifest 唯一映射且属于安全第三方的失败插件才可能被隔离；核心包、未知 ID、证据冲突一律 fail-closed。
- **Host API 默认只接受 loopback**；远端 Host 必须通过 `DSH_DEBUG_API_ALLOWED_HOSTS` 显式白名单。
- **Recovery 不碰敏感内容**：`.env` 等敏感条目只记录"存在但排除"，不复制、不恢复；不跟随 junction/symlink；不删除快照后的新文件。
- **修复有回滚保护**：pre/post-image hash 校验，用户改过文件返回 `ROLLBACK_CONFLICT`，绝不覆盖。
- **hotswap 只探测不执行**：缺少权威、稳定、带版本的生命周期合同就返回 `UNAVAILABLE`，绝不调用 `_dispose`/`refresh`/`update`。
- **费用是内置估算不是账单**；报告中的危险命令文本（如 `rm -rf`）只做风险分类，绝不交给 shell 执行。

## 测试与门禁

发布边界检查在仓库根目录运行，包测试在包目录运行：

```powershell
# 仓库根目录：检查只发布单包，并拒绝日志、凭据和 node_modules
.\scripts\Verify-Publication.ps1

# 包目录：安装测试依赖并跑全部离线回归
Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm test          # Node 回归（95 项）
npm run check     # build + 生成物一致性 + 语法 + workflow pin + Node 回归
npm run check:standalone
npm run check:integration
```

大部分回归不需要真实 DSH（临时目录合成 Profile/fake runtime）；需要本机服务的项会诚实返回 `UNAVAILABLE` 或跳过，不会拿静态 fixture 冒充真实验证。供应链门禁包括 `check:runtime-lock`、`sbom:check` 和确定性 SPDX/CycloneDX 清单（[`packages/dsh-plugin-debug/sbom/`](packages/dsh-plugin-debug/sbom/)）。

CI（Node 22/24 + PowerShell 7 主流程）、CodeQL、Dependabot 和手动真实兼容性 workflow 见 [`.github/workflows/`](.github/workflows/)。

## 维护须知

- 改功能先改 `src/`、`tools/`、入口脚本和测试；**不要手工编辑 `lib/` 和 `bundle-manifest.json`**（由 `npm run build` 生成）。
- 升级 pinned runtime 时同步更新 `tools/runtime/package-lock.json`、`Install-DSH-Agents.ps1` 固定清单和 SBOM，并重跑完整门禁。
- 插件 lockfile 使用国内镜像、runtime lockfile 使用官方 npm registry；更换安装源必须重新生成 lockfile 并重跑发布门禁。
- 不要把 `node_modules`、Profile state、日志、凭据、coverage 或测试输出提交进仓库。
- 未重跑 fresh-clone 门禁前，不要给新版本打 tag 或更新 `RELEASE-MANIFEST.json` 的发布字段。

## 许可证

MIT，版权归 `shine-233`。
