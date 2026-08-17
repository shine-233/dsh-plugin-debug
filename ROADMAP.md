# 维护路线图

这是维护顺序，不是对真实 DSH 兼容性的承诺。每一项只有在对应的证据门禁通过后，才会从“计划”移动到“已完成”。

## 已发布（0.8.4）

- 单包 `dsh-plugin-debug`，默认离线、metadata-only、fail-closed。
- `plugin_check`：离线仓库形态检查、技能目录识别、路径围栏和构建陷阱提示。
- `plugin_hotswap_check`：只读观察 Host 生命周期合同；不执行热切换。
- `dsh_agent_report`：只读生成有界 Session/Token/工具/风险报告；没有 Session 服务时明确返回 `UNAVAILABLE`。
- 真实 rc.6 隔离证据：Web/Host 启动、134 条 inventory、三个工具的 ToolRuntime dispatch，以及有数据但失败的 `SessionQuery` 报告均已验证；当前隔离 Profile 的 `session.create(minimal)` 也已通过。
- `SessionQuery` 报告实际读取 1 个 Session、15 条事件，识别 1 个失败回合、0 Tool Call、0 Token、`¥0.0000`，并以 `MISSING_CREDENTIAL` 失败闭合；这不等于成功模型或真实账单证明。
- `.github/workflows/ci.yml`、`.github/workflows/codeql.yml` 和 `.github/dependabot.yml` 已随 v0.8.4 source release 发布；CI、CodeQL、fresh-clone 和 108 文件发布边界证据均已通过。远端分支保护和安全设置仍以 GitHub 设置页/API 为准。
- Node 22/24、PowerShell 7 主流程、5.1 兼容解析、runtime 官方 advisory audit、fresh clone 和真实 tarball→解包→package-only Standalone 门禁。

## 下一优先级

1. 继续 opt-in compatibility lane：在明确获得 provider、model、费用上限和临时 Profile 授权后，验证成功模型响应、真实 Token/费用和无害模型 Tool Call；在未获授权前不发送 `session.prompt`。
2. 在一次性隔离 Profile 中评估第三方插件安装；`dsh-plugin-check` 不与 Debug 同装，hotswap 候选只保留静态 `MANUAL_REVIEW`，不能直接安装到生产 Profile。
3. 只有 DSH 提供公开、稳定、带版本的生命周期合同后，才重新评估真实 hotswap；在此之前不调用私有 dispose/refresh/update、不驱逐模块缓存、不启动自动 watcher。
4. 维护已发布的 SPDX/CycloneDX SBOM、runtime lockfile 漂移检查和 Node/PowerShell 质量门禁，依赖更新时重新生成并复验。
5. 继续维护 `deepseek-harness-study` 的最小示例插件工作台和“构建→注册→卸载”实验；学习仓库仍保持文档 fork 的边界，不强行声称是官方运行镜像。

## 暂不承诺

- 真正的运行时 Hot-swap：在 DSH 官方公开、稳定、带版本的生命周期合同出现前，不调用 `_dispose`、`refresh`、缓存驱逐或自动 watcher。
- 自动安装/卸载任意插件、默认修改 Profile、无鉴权远程启停、上传原始 Session/Tool 内容或接入外部 telemetry。
- 不承诺成功 provider/model 响应、真实 Token/费用账单、模型生成 Tool Call、生产第三方安装、生产 hotswap 或跨平台运行；这些都需要额外的运行时条件和明确授权。此前外部实例的 `agent-preset-invalid` / `deployment:persona` 重复注册只作为历史观察保留，不作为当前隔离 Profile 的普遍结论。
- npm registry 发布：目前路线是 GitHub source release；若改为 npm 分发，必须另做 provenance、签名、SBOM 和安装兼容性门禁。
