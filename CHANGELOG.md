# 更新记录

## 0.8.3（candidate，尚未发布）

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
- 当前 0.8.3 candidate 不复用 0.8.2 的 source SHA、时间戳或文件数。
