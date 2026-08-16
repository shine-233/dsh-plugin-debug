# DSH Debug Research Ledger

## jorinyang research (GitHub verified 2026-08-15)

The account `jorinyang` has a public repository named
[dsh-doctor](https://github.com/jorinyang/dsh-doctor). GitHub metadata reports
MIT, version `0.3.2`, and the inspected `main` commit was
`79418687575d499f9445b4ada7a6a01e18947e68`.

The repository is a real implementation, not only a README claim. The source
tree contains `src/diagnose.ts`, `src/repair.ts`, `src/journal.ts`,
`src/tool.ts`, `src/runtime.ts`, and `src/cli.ts`. The useful design shape is:

- read-only structured checks for environment, DSH home, Profile files,
  bundles, config mount, port, HTTP health, and disk;
- a separate repair command with explicit `safe`, `deps`, and `full` scopes;
- serializable undo records persisted to disk and replayed in LIFO order;
- a Cordis service exposed with `ctx.provide()` and lifecycle observations;
- a standalone CLI that remains available when the DSH Web process is down.

The implementation is not a complete automatic self-healing proof. Runtime
code records failed fibers and emits events, but does not automatically invoke
repair. Some repair operations are explicitly manual: Profile initialization,
`pnpm install --fix-lockfile`, and process termination. The journal also lacks
the containment, integrity, and post-image conflict checks required for a safe
general-purpose rollback. The repository's `full` process cleanup and shell
string construction are deliberately excluded from this project.

The local absorption decision is therefore: keep the diagnostic/plan/journal
shape, but preserve the narrower implementation already in this repository.
Automatic recovery may change only `guard-state.json` and `guard.patch.yml`,
requires an evidence-bound allowlist plan and explicit approval, records
pre/post hashes, refuses rollback conflicts, never edits the Profile manifest
or workspace, never changes `danger-full-access`, and never lets the model
execute tools. The new client report also makes privacy and completeness
explicit: no visible node text is persisted, deep ancestor search reports when
it is incomplete, and Tool Call truncation is machine-readable.

The same comparison motivated `tools/DSH-Repro.ps1`. `dsh-doctor` makes its
journal and CLI useful when the Web process is down; this project now adds the
offline handoff half as a separate Host action: `repro-export`. It uses an
allowlist projection and fixed artifact manifest rather than copying the
community tool's raw paths, shell operations, dependency installation, or
process cleanup. This is an absorption of the operational idea, not a copied
implementation or runtime dependency.

Adjacent public repositories were also checked: `dsh-clawshell` contains
error/metric/fiber insight and repair escalation code; `ClawShell` contains
health checks and self-repair experiments; `wukong-optimized-ClawShell`
contains backup/checkpoint/rollback and a debug skill. These are design
references only. Their README claims are not treated as runtime proof, and
repositories without a standard LICENSE file are not copied into this package.

更新时间：2026-08-15（中国标准时间）。本文件记录公开仓库的行为研究与本项目的独立实现边界。链接只作为设计参考；本项目不复制社区源码，也不把这些仓库加入运行时依赖。

## 已核对的公开方案

| 方案 | 公开仓库观察 | 对本项目的决定 |
| --- | --- | --- |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | 官方仓库以 “Everything is a Plugin” 为核心，Host、bundle、Client 和 profile 由插件机制组合 | 继续使用 DSH 作为宿主；本项目保持一个独立 bundle，不能脱离 DSH 单独提供 Host 能力 |
| [hust-open-atom-club/oh-dsh](https://github.com/hust-open-atom-club/oh-dsh) | 一站式社区发行版，统一 Web/TUI/桌面体验，并包含插件市场/分层安装方向 | 吸收“一键启动、统一入口、分层安装”的产品思路；不把 oh-dsh 作为运行时依赖 |
| [lire1131/dsh-undo-plugin](https://github.com/lire1131/dsh-undo-plugin) | 配置快照、undo/redo、离线 PowerShell CLI/GUI、启动异常横幅和导入导出 | 本项目已有 Profile/Workspace snapshot、restore、启动器和 Crash Guard；不复制其 GUI 或包加载方式 |
| [LingLambda/dsh-undo](https://github.com/LingLambda/dsh-undo) | 明确依赖尚未发布的 durable `surface/rewind` / `surface/restore` 事件；Session 保持 append-only；旧 Harness fail-closed | 本项目继续采用 `session-history`/`session-fork` 的追加式安全边界，不伪造删除或重写历史；待 DSH 原生事件可验证后再接入真正 rewind |
| [PerryLink/dsh-checkpoint-rewind](https://github.com/PerryLink/dsh-checkpoint-rewind) | 变更前快照、guard checkpoint、文件恢复、Session fork 的三阶段事务、配额和可恢复日志 | 本项目已具备可逆 snapshot/restore、receipt 和 fork；本轮新增 Crash Guard 集成 fixture。每次 Tool mutation 的自动 checkpoint、增量配额和完整三阶段 journal 仍列为后续增强，不声称已经吸收 |
| [BiBoyang/dsh-eval-harness](https://github.com/BiBoyang/dsh-eval-harness) | 每条 case 使用隔离 workspace/session，采集 JSONL/zstd trace，断言 Tool Call，并用 baseline 做 CI PASS/WARN/FAIL 门禁 | 本项目独立实现 metadata-only Trace contract、Eval 和 baseline gate；当前只读取 JSONL/Session history，zstd 解码和真实 headless LLM 回归仍未宣称完成 |
| [sandbaseai/sandbase-harness](https://github.com/sandbaseai/sandbase-harness) | 将 session、sandbox、audit trail、crash recovery 和可恢复事件流作为运行时一等能力 | 作为跨层审计模型参考；本项目不引入其运行时或数据库，先在 PowerShell/JSON 文件中保持零依赖 |
| [akira399/dsh-guardian](https://github.com/akira399/dsh-guardian) | MIT；本轮只读复核的 `main` 提交为 `5bf7ef3ad56d5e0b78e40071ac99d94b697e468b`；插件预检、重复 Tool Call 循环、Agent/Workflow 递归、中断感知和 `safeToRestart` | 已独立吸收预检、运行时循环/递归观察、冷却提示、事件上报和只读重启前状态检查；不复制源码，不引入实际重启脚本，不终止任务、不杀进程、不重启 Host、不禁用插件 |

## 当前吸收结果

- 鼠标元素来源已内置在本项目 Client bundle，支持插件、Module、Slot、CSS 证据和冻结页面 bridge。
- Host 侧覆盖 Profile/Workspace 快照、Session history/fork、插件启停、静态健康检查、Crash Guard、一键启动、Tool Call 元数据诊断、失败聚合、上下文/安全/会话健康审计。
- `crash-fixture` 走真实 `Start-DSH.ps1` 启动循环：第一次启动故意崩溃，Guard 生成第三方插件 quarantine patch，第二次启动只在 patch 生效后报告 Web ready。
- `trace-baseline` 比较两份脱敏 trace；错误结果、dispatch error、turn error 或 pending Tool Call 增加时门禁失败，模型路由、工具名和权限枚举变化会留下 warning。
- `incident-capture` 将跨层诊断组合成一份可哈希的本地 evidence bundle；只读采集与本地报告写入分开标记，最终结果使用 `COMPLETE`、`PARTIAL`、`UNAVAILABLE` 或 `FAIL`，避免用“报告文件写成功”冒充“DSH 已恢复”。
- Guardian 运行时观察器已经合入单包：它对短窗口内重复 Tool Call、Agent lineage、Workflow 深度和取消/失败中断做有界检测；`policy=auto` 只发送一次冷却提示，`policy=report` 只上报，不终止任务。
- Guardian 状态接口和 `Get-DSHGuardianStatus.ps1` 只读 `safeToRestart`；状态不安全时返回 `BUSY_DO_NOT_RESTART`，不会执行第三方项目中的实际重启流程。事件内存窗口和单条事件元数据有界，但 `events.jsonl` 当前按行追加、没有自动轮转，文档不把整个文件声明为有界。
- 模型辅助修复仍然是受限 advisory JSON：当前 DSH Host 没有明确的 no-tools planner 能力时直接 `UNAVAILABLE`；即使 Host 将来提供该能力，计划也必须绑定 incident/evidence/Profile/候选/有效期，并经过执行事件拒绝、schema/allowlist、人工 `-Force` 和 receipt 回滚流程。

## 2026-08-16 公共仓库补充核对

以下元数据通过 GitHub 公共只读 API 和各仓库公开 README 核对；没有使用
Token，也没有上传本地代码或诊断数据：

| 仓库 | 公开信号 | 本项目的吸收决定 |
| --- | --- | --- |
| [Areium/dsh-fail-logger](https://github.com/Areium/dsh-fail-logger) | MIT；记录 native/PTC/nested tool failure，去重、计数、排序、TTL 清理并脱敏；明确只在 `isError=true` 时记录 | 已吸收“失败归档”的元数据模型；继续不保存原始参数/结果，不把普通非零退出码冒充 Tool error |
| [fuhefei/dsh-sentinel](https://github.com/fuhefei/dsh-sentinel) | BSD-3-Clause；持久 file/command/http/process/port/webhook watch，lease owner、at-least-once wakeup、dock/sidebar/dashboard | 不作为 Debug 核心默认常驻 watcher；它会扩大常驻进程、网络和唤醒边界，后续须做独立 opt-in provider 和权限审查 |
| [Anionex/dsh-turn-rewind](https://github.com/Anionex/dsh-turn-rewind) | BSD-3-Clause；Change Ledger、预览、恢复前 rescue point、冲突检测和显式确认 | 已吸收可逆账本、snapshot/restore 和 fail-closed 方向；当前仍不改写原 Session，不声称 durable rewind |
| [PerryLink/dsh-checkpoint-rewind](https://github.com/PerryLink/dsh-checkpoint-rewind) | Apache-2.0；每次 mutation 前 checkpoint、git-first/copy fallback、三阶段 restore/fork、配额和 stale-plan fence | 已吸收 bounded snapshot、receipt、post-image 校验；自动捕获每次 mutation 和 Git 对象存储仍未加入，避免隐式 workspace 写入 |
| [BlockRunAI/dsh-clawrouter](https://github.com/BlockRunAI/dsh-clawrouter) | MIT；在危险 Tool 执行前由更强模型给 allow/deny/ask，并强调 fail-closed executor gate | 已吸收“执行前闸门”的概念为默认关闭的本地 Tool Policy；没有复制其外部 Provider、计费、模型路由或二次模型权限 |

这轮搜索还确认了 DSH 社区目录中存在桌面启动器、usage dashboard、session
import、browser 和多 Agent 项目，但它们与本 Debug 包的故障证据边界不同。
本项目只吸收可由当前 DSH rc.6 API 和本地回归证明的部分。

### 对“启动时禁用、页面通知、自动创建会话”的决定

这项能力已经吸收，但分成三个安全边界：

1. Host-side `Start-DSH.ps1` 只对明确映射的安全第三方失败候选生成可逆
   quarantine patch，最多重启一次；核心包、runtime include 和无法归因的
   条目不会自动禁用。
2. Client 通过有限 URL marker 和脱敏 inventory 显示启动保护通知，提供打开
   诊断的入口；不会把日志、命令、Tool 参数、凭据或完整路径放进 URL。
3. 自动诊断 Session 只有在 Host 声明 `diagnosticSessionPolicy` 为
   `automatic + no-tools` 时才创建，并按故障标记去重。没有该声明时结果为
   `UNAVAILABLE`，不创建普通可执行 Session。

这个分层保留了用户想要的“启动后自动处理”体验，同时避免 Debug 插件在不知情
的情况下获得执行权限或制造新的会话副作用。

## 未宣称完成的部分

- DSH 原生 durable rewind 事件在当前实际 rc.6 上没有被验证，因此本项目不能声称可以无损删除或重写对话历史。
- 当前真实 `3081` 的 Tool Call 没有在没有明确 Session ID 的情况下被读取；Host 配置里的 `danger-full-access` 不是 Tool 成功证据。
- 当前真实实例的运行时模型证据是 `deepseek-official/deepseek-v4-flash`；`gpt-5.6-sol` 只有在 Session history/request context 观察到时才会被报告为运行中。
- zstd Session 文件会被识别并标记为 `not-decoded`，不会假装已解码；后续可以在检测到本机可用解码器时增加显式 opt-in 读取。

## 检索边界

本轮先尝试了联网搜索服务，但匿名额度已耗尽；随后使用 GitHub 公共只读 API 核对仓库元数据、README 和文件树。没有使用 GitHub 密码、Token 或 API key，也没有向外部服务上传本地代码、Session、Cookie、Tool 参数或诊断文件。
