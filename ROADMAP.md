# 维护路线图

这是维护顺序，不是对真实 DSH 兼容性的承诺。每一项只有在对应的证据门禁通过后，才会从“计划”移动到“已完成”。

## 已发布（0.8.3）

- 单包 `dsh-plugin-debug`，默认离线、metadata-only、fail-closed。
- `plugin_check`：离线仓库形态检查、技能目录识别、路径围栏和构建陷阱提示。
- `plugin_hotswap_check`：只读观察 Host 生命周期合同；不执行热切换。
- `dsh_agent_report`：只读生成有界 Session/Token/工具/风险报告；没有 Session 服务时明确返回 `UNAVAILABLE`。
- 真实 rc.6 隔离证据：Web/Host 启动、inventory 和三个工具的 ToolRuntime dispatch 已验证；空 SessionQuery 和外部 `session.create` 限制仍把真实业务报告留在未完成状态。
- `.github/workflows/ci.yml`、`.github/workflows/codeql.yml` 和 `.github/dependabot.yml` 已随 v0.8.3 source commit 发布；远端设置仍以 GitHub 设置页/API 为准。
- Node 22/24、PowerShell 7 主流程、5.1 兼容解析、runtime 官方 advisory audit、fresh clone 和真实 tarball→解包→package-only Standalone 门禁。

## 下一优先级

1. 修复旧 `v0.8.2` release notes 的历史说明和 Markdown 换行；保持旧 tag 不动，并让读者明确它不是当前 v0.8.3 证据基线。
2. 继续 opt-in compatibility lane：在 DSH 修复 `session.create` 的 `deployment:persona` 重复注册或提供新的 pinned runtime 后，验证有数据 Session、模型请求和完整 Agent 报告；在此之前只保留已取得的 Web/Host/inventory/ToolRuntime 分层证据。
3. 维护已发布的 SPDX/CycloneDX SBOM、runtime lockfile 漂移检查和 Node/PowerShell 质量门禁，依赖更新时重新生成并复验。
4. 继续维护 `deepseek-harness-study` 的最小示例插件工作台和“构建→注册→卸载”实验；学习仓库仍保持文档 fork 的边界，不强行声称是官方运行镜像。

## 暂不承诺

- 真正的运行时 Hot-swap：在 DSH 官方公开、稳定、带版本的生命周期合同出现前，不调用 `_dispose`、`refresh`、缓存驱逐或自动 watcher。
- 自动安装/卸载任意插件、默认修改 Profile、无鉴权远程启停、上传原始 Session/Tool 内容或接入外部 telemetry。
- 在 rc.6 的 `agent-preset-invalid` / `deployment:persona` 重复注册未解决前，不承诺真实有数据 Session 创建、模型请求或端到端 Agent 报告；这属于 DSH 运行时外部限制，不通过修改 Debug 插件绕过。
- npm registry 发布：目前路线是 GitHub source release；若改为 npm 分发，必须另做 provenance、签名、SBOM 和安装兼容性门禁。
