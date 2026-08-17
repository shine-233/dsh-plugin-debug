# 更新记录

## 0.8.4（2026-08-17，GitHub source release）

- Agent 报告现在兼容 DSH token meter 的 `assistant/chunk` usage 样本，并按同一 `turn/step` 用最终样本替换早期样本，避免重复计 Token。
- 增加 `cacheWriteTokens` 展示；由于供应商计费规则不统一，当前内置费用估算不会擅自把缓存写入当成已知计费项。
- 增加版本化的脱敏 Session JSON 离线入口：`Debug-DSH.ps1 -Action agent-report`；只读取明确文件，拒绝符号链接，不扫描 Profile/凭据目录、不联网、不执行输入命令。
- 收紧报告历史读取的总事件预算；预算耗尽返回 `PARTIAL`，同时补充中文傻瓜式使用说明和发布候选边界。
- 收紧 `plugin_hotswap_check` 的 fail-closed 门禁：inventory 被截断、目标没有 live fiber 或祖先链超过扫描上限时，不再返回 `SUPPORTED`，统一留下可审计的人工复核 finding。
- 增加离线 `plugin_hotswap_preflight` 源码预检：限制文件/字节预算，识别 shell 执行、私有生命周期、缓存清理、无鉴权控制面、非原子 patch、缺少回滚/队列/核心保护/测试/CI 等静态线索；不 import、不安装、不运行候选，也不把静态结果当成漏洞利用证明。
- CI 的 GitHub Actions 改为完整 40 位 commit SHA，并增加 `check:workflow-pins` 回归；包根目录的开发依赖与 pinned runtime 分开做官方 npm advisory 高危审计，避免只审计生产依赖而漏掉构建工具。
- 上游 `dsh-whale-report` 已在 2026-08-17 重新核对到 `main` 提交 `b3de4a7d8851f63757078427ecfda52bc908961f`、版本 `0.4.0`；本包只吸收本地确定性报告引擎，不吸收其凭据/余额/网络探针或 `rm -rf lib` 构建步骤。
- Windows standalone 的 Known-good / Live API 测试夹具改用仅监听 loopback 的原始 TCP HTTP 实现，不再依赖 `HttpListener` 的机器级 URL ACL；这是测试基础设施修复，不会扩大插件的网络或命令执行能力。
- 这批改动已提交为 `7fce25118098cbceb7f3f24fa391d75324318b11` 并推送到 GitHub `main`；远端精确 fresh clone 已通过 95/95 Node 测试、canonical integration、61 文件 standalone、108 文件 pack 和发布验证器。版本发布到 GitHub source release，不发布到 npm registry。

## 0.8.3（2026-08-17，GitHub source release）

- 增加离线 `plugin_check` 仓库健康检查，支持 bundle、tool-bundle、registry、skill 和 collection 形态，并限制文件/字节预算。
- 增加只读 `plugin_hotswap_check` capability probe：分层报告 Host 合同和插件风险，但不调用 `_dispose`、`refresh`、`update` 或任何缓存清理。
- 增加只读 `dsh_agent_report`：借鉴 `dsh-whale-report` 的确定性 Agent 报告形状，从 Host 提供的持久化 SessionQuery 或当前内存会话读取有界事件，生成 Token、工具调用、失败、风险和内置估算费用报告；费用不是账单，不调用模型、不执行命令、不读取凭据、不写回 Session。
- hotswap 探测现在对 `@deepseek-ai/*` 核心命名空间和 `include:` 组合条目 fail-closed；缺少权威来源、稳定标记或可审计版本时返回 `UNAVAILABLE`，省略目标只做 Host 级观察。
- 增加生成物 SHA-256 门禁和全包 JavaScript 语法门禁，CI 先执行锁文件安装，再拒绝 dirty `lib/`/bundle manifest。
- CI 增加通过官方 npm advisory API 的高危生产依赖审计，覆盖包本身和 pinned DSH runtime；镜像源不支持 audit endpoint 时不把 404 当成安全通过。
- fresh-clone 门禁增加固定 runtime、Standalone、Recovery、Known-good、实际 npm tarball 解包 smoke。
- package-only Standalone 对冷启动 HttpListener readiness 只做一次有界重试；协议或业务断言失败仍立即失败。
- 发布 helper 改为定位仓库根目录、禁止自动 `git init`，并提供无副作用 `-DryRun`。
- 启动器缺少 runtime 时改用 `npm ci`，要求存在 `package-lock.json`；quickstart 明确 runtime 安装前置。
- 明确不吸收未经官方生命周期合同证明的 hotswap：不调用 `_dispose`/`refresh`、不监听 `package.json`、不开放无鉴权启停接口。
- 记录真实 rc.6 隔离验证边界：Web/Host、inventory 和三个工具的 ToolRuntime dispatch 已通过；空 SessionQuery 只证明注册/调用链，不能证明有数据报告。`session.create` 仍受外部 `agent-preset-invalid`（`deployment:persona` 重复注册）阻塞。
- 记录仓库维护设施已经写入源代码：CI、CodeQL 和 Dependabot 配置存在；远端分支保护、安全告警和自动修复仍须发布后从 GitHub 设置复核。

## 0.8.2（历史基线，证据需与 tag 复核）

- 上一个 GitHub source release 的历史基线；`main`、tag/source archive 和 release
  body 的证据需要彼此复核，不能把它当成当前候选的发布证明。
- 其历史发布记录以 `RELEASE-MANIFEST.json` / `SOURCE-SNAPSHOT.md` 的历史段落为准。
- source commit 为 `591ca0da959465a1207030cd7eb91372d8e90b2a`；精确远端 fresh clone、102 文件 pack/extract smoke、SPDX 2.3/CycloneDX 1.5 SBOM（584 components）和 runtime lock 漂移检查均已通过。
- 当前发布路线仍是 GitHub source release，没有发布到 npm registry；provenance、签名、npm 安装和版本兼容门禁留待未来另行设计。
