# DSH Debug Plugin

这是一个把 DSH 检测、调试、日志、恢复、Crash Guard 和一键启动能力合并到一起的单一插件。运行时包名是 `dsh-plugin-debug`，不依赖插件商店，也不会安装或调用 `dsh-plugin-store`。

## 这个插件解决什么问题

- 启动前检查 Profile、bundle、patch、runtime 和本地依赖是否一致。
- DSH 启动失败或 Web ready 后发现第三方插件失败时，生成可逆的 `disabled: true` Guard patch，并最多进行一次受控重启。
- 启动冲突时不杀掉已有 DSH，也不覆盖已有 Profile；默认切换到新的 loopback 端口和隔离 Profile。
- 在 Web 页面提供鼠标来源检查器和诊断页，报告插件、Module、Slot、客户端错误、Host 插件清单、Tool Call 元数据和运行时线索。
- 提供 Profile/Workspace snapshot、known-good restore、incident capture、脱敏 trace/eval、资源压力和失败归档工具。
- 在 Host 明确声明 no-tools planner 能力时，才允许创建隔离的修复规划 Session；普通 Host 上保持 `UNAVAILABLE`，不会偷偷创建一个带工具的 Session。

诊断结果是证据和线索，不会把“发现失败插件”夸大成已经证明根因，也不会把“报告写入成功”夸大成 DSH 已经恢复。

## 安装

使用仓库中的一键入口：

```powershell
.\Start-DSH-Debug.ps1 -NoBrowser
```

默认使用 `debug` Profile 和 `127.0.0.1:3081`，首次运行把当前目录中的 bundle 离线安装到该 Profile。需要后台运行时使用 `Start-DSH-Debug.vbs`。

也可以通过 DSH CLI 安装本地包：

```powershell
dsh plugin --profile debug add . --offline
```

`Start-DSH-Combined.*` 只在你先运行 `tools\\Install-DSH-Agents.vbs` 后才会启用可选的 Kimi/Codex Agent overlay；overlay 不是 Debug 核心依赖。

## 启动故障处理

启动器默认开启一次性 Crash Guard。它遵守以下顺序：

1. 读取当前 Profile 的插件清单和安全候选。
2. 只考虑明确属于第三方插件、且能由当前 Profile manifest 映射的候选；核心 `@deepseek-ai/*` 和 runtime `include` 项不会自动禁用。
3. 对启动日志或 `pluginInventory/list` 已观察到的失败插件写入 Guard state 和可逆 patch。
4. 最多重启一次并重新等待 Web ready；第二次仍失败时进入 `degraded`，不会无限自愈。

因此“有问题就直接禁用”不是无条件删除：它只自动隔离有明确证据的安全第三方候选，无法归因时保留人工复核。

如果目标端口已有其他 DSH 实例，而目标 Profile 尚未安装 Debug bundle，启动器默认自动使用类似 `web-debug-3082` 的隔离 Profile。原实例、原端口和原 Profile 不会被修改。要恢复严格拒绝模式，可传：

```powershell
.\tools\Start-DSH.ps1 -NoIsolateOnConflict -NoErrorDialog
```

## 页面通知和修复 Session

Web Client 会把 Host inventory 中的 failed plugin、动态插件运行错误和 Slot 渲染错误显示在诊断页，并持续刷新运行时状态。页面提示只报告“发现了什么”，不会伪造因果结论。

修复规划默认是只读 dry-run：

```powershell
.\Debug-DSH.ps1 -Action repair-assist -Profile debug -Port 3081
```

只有 `host.describe` 明确声明 no-tools planner 能力时，这个动作才会创建隔离的最小 Session；它会拒绝已有用户 Session、工具调用、审批事件、执行事件、未知字段和过期证据。当前 DSH rc.6 未提供该能力时，结果为 `UNAVAILABLE`，这是预期的安全结果。任何实际 patch 应使用显式 `repair-apply -Force`，并保留 receipt 供回滚。

## 测试

测试源码和脱敏 fixture 会随 GitHub 源码一起发布，便于别人复现实现和检查发布边界：

```powershell
Set-Location .\packages\dsh-plugin-debug
npm ci --ignore-scripts
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHProvenanceIntegration.ps1
.\tools\Test-DSHLauncherConflict.ps1
.\tools\Test-DSHCrashGuard.ps1
.\tools\Test-DSHRuntimeSupervisor.ps1
.\tools\Test-DSHTraceProfile.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
Pop-Location

Set-Location .
.\scripts\Verify-Publication.ps1
```

`tools\\fixtures` 中的 JSON/HTML 是合成且脱敏的输入数据，会被 trace 和浏览器契约测试直接引用。Crash Guard、启动冲突和 runtime supervisor 的 fake DSH 会在测试运行时创建到临时目录，测试结束后清理；仓库中没有真实 Profile、日志、凭据或崩溃转储。

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
