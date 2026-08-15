# dsh-plugin-debug

这是一个把 DSH 检测、调试、恢复、插件健康检查、崩溃隔离、事故取证、Trace 分析和一键启动能力合并到一起的单一插件。运行时包名是 dsh-plugin-debug，不依赖插件商店，也不会安装或调用 dsh-plugin-store。

## 适用范围

它适合在 Windows PowerShell 中排查以下问题：

- DSH Profile、bundle、patch 或本地 runtime 清单不一致；
- Web 启动失败、第三方插件加载失败、启动后反复崩溃；
- 页面元素的插件来源不清楚、Slot/Module 归属冲突；
- Tool Call、权限元数据、Session 历史或上下文装载异常；
- 需要生成脱敏事故包、Trace baseline、可逆快照或受限 repair receipt。

诊断输出是证据和线索，不会把“发现失败插件”写成已经证明根因，也不会把“报告写入成功”写成 DSH 已经恢复。

## 安装与一键启动

从本目录运行：

```powershell
.\Start-DSH-Debug.ps1 -NoBrowser
```

默认使用 debug Profile、127.0.0.1:3081，并离线安装本地 bundle。也可以直接使用 DSH CLI：

```powershell
dsh plugin --profile debug add . --offline
```

Start-DSH-Combined.* 是可选的 Agent overlay 入口。只有显式运行 tools\Install-DSH-Agents.vbs 后才会安装 overlay；它不是 Debug runtime 依赖，也不是插件商店。

## 能力总览

| 能力 | 提供内容 | 重要边界 |
| --- | --- | --- |
| 页面来源标注 | 读取 data-dsh-plugin、data-dsh-module、CSS、Slot，显示插件、Module、Slot 和证据等级 | 未标记的 DOM 显示未知，不猜测来源 |
| Host 诊断 | 上下文、插件健康、Session 健康、安全审计、资源压力、失败归档 | API 不可用时保留 PARTIAL/UNAVAILABLE |
| Crash Guard | 启动日志和 inventory 识别安全第三方候选，写入可逆 patch，最多重启一次 | DSH 核心包、runtime include、未知或歧义项不自动禁用 |
| 启动回执 | 写入 startup-incident.json，记录启动状态、关联 ID、重启次数和隔离插件 | 不写原始日志、Tool 参数、凭据或完整路径 |
| 客户端诊断时间线 | 80 条上限的脱敏 breadcrumb 环形缓冲，记录启动、鼠标来源、插件清单、Slot 和客户端错误顺序 | 超出上限记录 dropped；不保存 Tool 参数、正文、DOM 文本或凭据 |
| Snapshot/Recovery | Profile、Workspace、known-good 检查点和追加式 Session fork | 不删除快照之后新文件，不重写原 Session |
| Repair | 受限计划、allowlist、pre/post-image hash、receipt 和冲突回滚 | 用户改过文件时返回 ROLLBACK_CONFLICT，不覆盖改动 |
| Trace/Incident | metadata-only Trace、baseline、autopsy、跨层事故包和 repro 导出 | 不保留 Tool 参数、结果正文、会话正文、Cookie 或 token |
| 插件二分定位 | 根据脱敏 inventory、失败证据和 manifest 生成候选顺序与人工步骤 | 只读计划，不自动禁用、不写 Profile、不执行命令 |
| 诊断报告对比 | 比较两次诊断/事故报告的状态、计数和 Issue code | 发现消息、路径、命令或凭据字段时返回 `MANUAL_REVIEW` |
| 插件静态预检 | 离线扫描 JS/MJS/CJS 的静态 `inject` 声明和 `ctx.*` 服务使用 | 不执行插件代码；动态访问和超出扫描上限转 `MANUAL_REVIEW` |
| 依赖图检查 | 读取 Profile/package manifest 和已有 package metadata，报告缺失依赖、循环和未引用本地包 | 不安装、不执行 package code、不修改 Profile；核心 DSH 包受保护 |

## 启动故障处理

启动器按以下顺序工作：

1. 读取当前 Profile manifest、插件 inventory 和启动日志。
2. 只接受 manifest 明确映射的安全第三方插件候选。
3. 为观察到失败的候选写入 guard-state.json 和 guard.patch.yml。
4. 最多进行一次受控重启，并重新等待 Web ready。
5. 第二次仍失败时返回 degraded 或 failed，不会无限重试。

如果端口已经被其他 DSH 实例占用，启动器不会杀进程、覆盖 Profile 或强行接管端口；它会在可用时选择隔离 Profile 和 loopback 端口。页面通知只报告观察到的故障，不把相关性伪装成因果结论。

页面只有在 Host 同时声明 diagnosticSessionPolicy.automatic=true 和 mode=no-tools 时，才允许自动创建隔离的诊断规划 Session。普通 rc.6 Host 没有这个能力时返回 UNAVAILABLE，不会创建普通的可执行 Session。

## 插件二分定位计划

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

每一步都标记 humanApprovalRequired=true、executesCommand=false、changesProfile=false 和 changesWorkspace=false。safe 只是安全候选分类，不是根因证明。

`diagnostics-diff` 是离线、只读的比较器。它只保留 `status`、`result`、`count`、`schemaVersion` 和安全格式的 Issue code；不读取或输出原始消息、完整路径、URL、命令、Tool 参数、结果正文、Cookie、Token 或凭据。如果任一输入违反这个边界，比较会停止并返回 `MANUAL_REVIEW`。

静态插件预检只读取指定的 JS/MJS/CJS 文件，移除注释和字符串后检查 `ctx.*` 服务是否在静态 `inject` 列表中；它不会 import、require 或执行目标插件。无法静态确定的动态 `ctx[...]`、动态 inject、文件数量/大小上限会进入 `MANUAL_REVIEW`，不自动修改插件或 Profile：

```powershell
.\Debug-DSH.ps1 -Action plugin-preflight -InputPath .\path\to\plugin -PreflightPath .\state\preflight.json
```

依赖图检查同样是离线只读分析，接受包含 `profileManifest`/`manifest` 和可选 `packages` metadata 的 JSON，不调用 npm、pnpm 或 DSH CLI：

```powershell
.\Debug-DSH.ps1 -Action plugin-dependency-graph -InputPath .\tools\fixtures\plugin-dependency-graph.json
```

Trace loop 分析只在有限窗口内比较脱敏事件的稳定签名，输出重复次数和索引，不输出消息、路径、命令或 Tool 参数；检测到敏感字段时返回 `MANUAL_REVIEW`：

```powershell
.\Debug-DSH.ps1 -Action trace-loop -InputPath .\tools\fixtures\trace-loop.json -WindowSize 12 -RepeatThreshold 3
```

## 公开的测试程序

测试脚本和脱敏 fixture 会随 GitHub 源码发布，便于别人检查实现和复现边界：

```powershell
npm ci --ignore-scripts
npm test
npm run check
npm run check:standalone
npm run check:integration
.\tools\Test-DSHBisect.ps1
.\tools\Test-DSHDiagnosticsDiff.ps1
.\tools\Test-DSHPreflight.ps1
.\tools\Test-DSHDependencyGraph.ps1
.\tools\Test-DSHTraceLoop.ps1
.\tools\Test-DSHCrashGuard.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1
.\tools\Test-DSHLauncherConflict.ps1
.\tools\Test-DSHGuard.ps1
.\tools\Test-DSHPluginHealth.ps1
.\tools\Test-DSHPluginState.ps1
.\tools\Test-DSHRecovery.ps1
.\tools\Test-DSHSelfRepair.ps1
.\tools\Test-DSHTraceProfile.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
```

Test-DSHStandalone.ps1 还会检查 Trace 循环分析、插件二分的保护边界和隐私契约，以及：

- 所有公开入口、工具和 fixture 是否随包存在；
- PowerShell Parser 是否为零错误；
- Debug-DSH.ps1 是否能正确传递 Action、InputPath、开关和重复参数；
- 二分计划是否保护核心包、标记歧义、保持输入不变并且不泄露原始故障消息；
- Crash Guard 是否只隔离安全候选、写入可逆 patch 并生成 recovered 启动回执；
- Repair 是否拒绝递归危险字段，且在 post-image 变化时返回 ROLLBACK_CONFLICT；
- 临时 Profile、workspace、runtime、logs 和 state 是否在测试结束后清理。

所有回归使用临时目录和合成数据，不会停止现有 DSH，也不会修改真实用户 Profile。Test-DSHPointerBrowser.ps1 需要 Python、npx 和 Playwright 浏览器运行时；依赖缺失时报告 UNAVAILABLE，不会把静态 HTML 冒充真实 Web 验证。

## 如何更新功能和发版

1. 在 src/、tools/、入口脚本中修改源码，同时添加对应 Node/PowerShell 回归测试。
2. 不手工编辑 lib/ 和 bundle-manifest.json，由 npm run check 重新构建。
3. 按 SemVer 更新 package.json，同步 package-lock.json。
4. 运行 npm test、npm run check、Test-DSHStandalone.ps1、相关工具测试和根目录 scripts/Verify-Publication.ps1。
5. 运行 npm pack --dry-run --json --ignore-scripts，将文件数量同步到根目录的 RELEASE-MANIFEST.json 和 SOURCE-SNAPSHOT.md。
6. 检查 git diff --check、敏感文件和待提交内容；从 fresh clone 重跑后再提交和 push。

不要提交 node_modules、.dsh、.codex、Profile state、logs、coverage、credentials、临时 fake runtime 或测试输出。新功能必须继续保持离线、metadata-only 和 fail-closed 安全契约。

## 目录结构

```text
src/                         Web Client 来源标注源码
lib/                         构建后的 DSH bundle
DSH-Provenance.ps1           完整统一调度入口
Debug-DSH.ps1                简短公开入口
Start-DSH-Debug.*             Debug 一键启动入口
Start-DSH-Combined.*          Debug + 可选 Agent overlay
tools/                       Host 诊断、恢复、Crash Guard、测试程序
tools/fixtures/              合成且脱敏的 trace、pointer、bisect 输入
tests/                       Node 运行时测试
```

## 许可证与旧模块

本包使用 MIT 许可证，版权归 shine-233。dsh-plugin-store 不在包内，也不在项目目录中；旧 provenance、debug-suite 和 one-click 源码已经迁移到本包后移除，当前不创建第二个公开插件，也不恢复插件商店。
