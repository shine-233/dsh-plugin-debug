# 更新记录

## 0.8.5（2026-08-22，DSH 0.1.1-rc.2 适配）

- pinned runtime 从 `@deepseek-ai/dsh@0.1.0-rc.6` 升级到 `0.1.1-rc.2`：`tools/runtime/package.json` 与 `package-lock.json` 全量重新生成，`Start-DSH.ps1` 的安装提示与运行时描述同步。
- 上游在 `0.1.x` 后期把大量内部包改为 `peerDependencies` 声明；本轮 lockfile 重生成时补齐了这条 peer 闭包（`dsh-invariants`、`dsh-scope`、`dsh-shell`、`react`/`react-dom` 等 29 个包），锁定条目从 487 增至 516，避免 `npm ci` 后真实启动因缺包失败。
- 适配验证证据：`check:runtime-lock` PASS（516 条目）；scratch 目录 `npm ci` 实装 453 包成功；`node .../dsh/lib/bin.js --version` 输出 `0.1.1-rc.2`；Node 测试 95/95 通过；`npm pack --dry-run` 仍为 108 文件。这是离线/隔离层验证，不等于真实有数据 Session 或生产 Profile 兼容证明。
- 包内 devDependency `@deepseek-ai/dsh-tools` 升到 `0.1.1-rc.2`；`peerDependencies` 范围保持 `>=0.1.0-rc.6 <0.2.0` 不变，继续兼容 rc.6 及以上。
- `tools/Install-DSH-Agents.ps1` 的外部 Agent Provider 固定清单同步到 `0.1.1-rc.2`（16 个包均已核对存在于该版本）。
- 测试 fixture 与 mock 中的宿主版本字符串同步到 `0.1.1-rc.2`；SPDX/CycloneDX SBOM 按 0.8.5 与新依赖树重新生成。
- 维护者备注：npm 11 对该依赖树做标准 peer 解析会出现长时间回溯，且 `--package-lock-only` 模式不落盘传递 peer；本轮采用 legacy 基座解析 + 按官方 registry 元数据确定性补全闭包的方式重建 lockfile，并用完整 `npm ci` 复验。使用者只需正常 `npm ci`，不受影响。

## 0.8.4（2026-08-17，GitHub source release）

- Agent 报告现在兼容 DSH token meter 的 `assistant/chunk` usage 样本，并按同一 `turn/step` 用最终样本替换早期样本，避免重复计 Token。
- 增加 `cacheWriteTokens` 展示；由于供应商计费规则不统一，当前内置费用估算不会擅自把缓存写入当成已知计费项。
- 增加版本化的脱敏 Session JSON 离线入口：`Debug-DSH.ps1 -Action agent-report`；只读取明确文件，拒绝符号链接，不扫描 Profile/凭据目录、不联网、不执行输入命令。
- 收紧报告历史读取的总事件预算；预算耗尽返回 `PARTIAL`，同时补充中文傻瓜式使用说明和发布边界。
- 收紧 `plugin_hotswap_check` 的 fail-closed 门禁：inventory 被截断、目标没有 live fiber 或祖先链超过扫描上限时，不再返回 `SUPPORTED`，统一留下可审计的人工复核 finding。
- 增加离线 `plugin_hotswap_preflight` 源码预检：限制文件/字节预算，识别 shell 执行、私有生命周期、缓存清理、无鉴权控制面、非原子 patch、缺少回滚/队列/核心保护/测试/CI 等静态线索；不 import、不安装、不运行候选，也不把静态结果当成漏洞利用证明。
- CI 的 GitHub Actions 改为完整 40 位 commit SHA，并增加 `check:workflow-pins` 回归；包根目录的开发依赖与 pinned runtime 分开做官方 npm advisory 高危审计，避免只审计生产依赖而漏掉构建工具。
- 上游 `dsh-whale-report` 已在 2026-08-17 重新核对到 `main` 提交 `b3de4a7d8851f63757078427ecfda52bc908961f`、版本 `0.4.0`；本包只吸收本地确定性报告引擎，不吸收其凭据/余额/网络探针或 `rm -rf lib` 构建步骤。
- 真实隔离 Host 现在已经验证有数据的 `SessionQuery` 失败报告：1 个 Session、15 条事件、1 个失败回合、0 Tool Call、0 Token、`¥0.0000`；`session.create(minimal)` 在当前隔离 Profile 通过，但无 provider 凭据的模型请求仍返回 `MISSING_CREDENTIAL`。这不等于成功模型、真实账单或生产 Profile 兼容证明。
- 2026-08-18 发布后文档补记：用户现有 `web` Profile 在 `-NoInstall -NoPluginInstall`、无模型请求的条件下完成真实启动复核，HTTP 200、`host.describe`、134 条 inventory 和 Debug active 均通过；Profile manifest/patch 哈希未变，启动进程已按 PID 回执清理。这是现有 Profile 的只读启动兼容证据，不是第三方生产安装或成功模型证明。
- 同日重新运行第三方边界检查：`dsh-plugin-check` typecheck 与 81/81 测试通过，但与 Debug 同装仍会冲突；Whale 研究副本缺少声明的 `zod`；Jarvan hotswap 缺少声明入口；两个 hotswap 候选均被严格离线预检判为 `MANUAL_REVIEW`，没有执行真实切换。
- Windows standalone 的 Known-good / Live API 测试夹具改用仅监听 loopback 的原始 TCP HTTP 实现，不再依赖 `HttpListener` 的机器级 URL ACL；这是测试基础设施修复，不会扩大插件的网络或命令执行能力。
- 修复 GitHub CI 的 tarball exact-lib 白名单和 npm pack notice 解析，并在精确远端提交 `687dbaba3897a50ff2c797049ad9755eb76576d5` 上重新通过 GitHub CI、CodeQL、fresh clone、95/95 Node 测试、集成测试、61 文件 standalone 和 108 文件发布边界验证；本版本作为 GitHub source release 发布，不发布到 npm registry。

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
