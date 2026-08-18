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
| [ssipbss/dsh-savepoint](https://github.com/ssipbss/dsh-savepoint) | MIT；本次直接审计 `main` 提交 `9cf1524ff8135a2aed94c9c51128a4410d51017e`；before/after 存档、quarantine、三路 surgical rollback、独立 PowerShell 恢复 | 吸收变更事务、局部回退、冲突报告和独立恢复的设计形状；不复制源码、`persist-bundle`、凭据快照或自动 `danger-full-access` fallback。当前仍没有把它当成真实 DSH 运行时证明 |
| [omdsh-dev/dsh-plugin-check](https://github.com/omdsh-dev/dsh-plugin-check) | MIT；审计基线 `397aa26df241aca530aa65a08484a664f7d555ad`；形态分流、manifest/patch/build/hub 检查、报告和 73 个静态测试 | 已把安全的规则形状和负例测试并入现有 `plugin_check`；保持一个工具注册、无额外运行时依赖、offline-only hub；不复制其宿主 peer 导入、`gh api`/Git 网络行为或 basename 收录判断 |
| [SenmuuuuW/dsh-whale-report](https://github.com/SenmuuuuW/dsh-whale-report) | MIT；2026-08-17 公开 API 复核的 `main` 提交为 `b3de4a7d8851f63757078427ecfda52bc908961f`；版本仍为 `0.4.0`；19 stars；报告引擎、测试和 Ubuntu CI；另有余额/凭据/网络探针和 `rm -rf lib` 构建脚本 | 吸收只读确定性报告的统计、风险、覆盖范围和估算形状，独立实现为 `dsh_agent_report`；拒绝余额探针、`.credentials.yaml`/`.env` 读取、外部网络、完整 UI、上游运行时依赖和 Unix-only 构建命令。当前 `rm -rf` 仅用于识别事件文本，绝不交给 shell；报告不把文本线索写成执行证明 |
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
- Guardian 状态接口和 `Get-DSHGuardianStatus.ps1` 只读 `safeToRestart`；状态不安全时返回 `BUSY_DO_NOT_RESTART`，不会执行第三方项目中的实际重启流程。事件内存窗口、单条事件元数据和 `events.jsonl` 当前文件加轮转文件均有界；默认每个文件 256 KiB、最多 3 个文件，配置范围经过限制，只处理 Debug 自己的 guardian 日志。
- 模型辅助修复仍然是受限 advisory JSON：当前 DSH Host 没有明确的 no-tools planner 能力时直接 `UNAVAILABLE`；即使 Host 将来提供该能力，计划也必须绑定 incident/evidence/Profile/候选/有效期，并经过执行事件拒绝、schema/allowlist、人工 `-Force` 和 receipt 回滚流程。

## `dsh-plugin-check` 审计与吸收（2026-08-16）

对照仓库为 [omdsh-dev/dsh-plugin-check](https://github.com/omdsh-dev/dsh-plugin-check)，
审计基线为 `397aa26df241aca530aa65a08484a664f7d555ad`，许可证 MIT。临时副本实际运行了
`npm ci --ignore-scripts` 和 `npm run check`：typecheck、73 个测试和 build 均通过；这只是
候选副本的构建证据，不是 DSH 真实 Profile、Hub 或模型任务证据。

候选最有价值的部分是“先识别仓库形态，再检查对应协议”：registry 的 `dsh.plugin.json`、
skill 的 `SKILL.md`、collection 的 `catalog.json`、bundle/tool-bundle 的 package/patch/build
边界。它还提醒我们需要检查路径 containment、重复/核心 row、TypeScript 产物残留和标准
`dsh plugin --profile ... add` 安装文档。当前 `plugin_check` 已吸收这些规则，但仍由本项目
现有适配层注册一次同名工具；不会再把候选的入口复制成第二个 `plugin_check`。

已实现并有回归测试的边界：

- manifest 的 `main`、`types`、patch 和 registry `main/client.main` 必须是仓库内普通文件；
  拒绝绝对路径、词法逃逸、符号链接和 realpath/junction 逃逸；
- patch 支持有限的 `insert/update/disable` section、`config` 嵌套和行内注释，检查缺 id、
  重复 row id、核心 `tools/session/llm/web/permission` 覆盖和 package identity；
- 静态检查 TypeScript 扩展名 import、`rewriteRelativeImportExtensions`、`tsconfig extends`
  的仓库根围栏、lib 中残留 `.ts` import/worker URL、install lifecycle script 和资源预算；
- registry、skill、collection 走单独的最小契约，并在报告中标出 `kind`；
- 报告明确写出 `hub.status=skipped`，说明本次没有运行 package manager/build/shell/git/gh，
  不联网、不读取本机 GitHub 登录态，也不把未验证的收录状态判为 PASS。

明确不吸收候选的现状：

- 候选虽然描述“零依赖”，但入口直接导入 `@deepseek-ai/cordis` 和 `@deepseek-ai/dsh-tools`；
  更准确的说法是“不依赖额外 YAML/semver 业务库”，不能当作脱离 DSH 的独立程序；
- 候选 Hub 路径会调用 `gh api` 和 `git remote`，远端失败时 skipped，且按 basename 匹配，
  不能提供可信的 owner/repo 精确发布门禁；
- 候选仓库没有 GitHub Actions CI，README 的“38 用例”也与当前静态统计的 73 个 `it(...)`
  不一致；本项目以本地真实退出码、fresh-clone 和发布验证器为准；
- 候选 patch 解析是受限行级 YAML 近似，不等于完整 YAML/PatchOptions schema；当前也只承诺
  检查可验证的结构子集，不把 patch 健康检查说成完整 YAML 验证。

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

### 2026-08-16 在线复核后的新增吸收

本轮直接读取了 [dsh-guardian](https://github.com/akira399/dsh-guardian)、
[dsh-plugin-doctor](https://github.com/zoahdev/dsh-plugin-doctor)、
[dsh-doctor](https://github.com/jorinyang/dsh-doctor)、
[dsh-bisect-debug](https://github.com/PangYiMing/dsh-bisect-debug)、
[dsh-fail-logger](https://github.com/Areium/dsh-fail-logger) 的公开 README 和
GitHub API 元数据，并核对了 [VS Code Extension Bisect 文档](https://code.visualstudio.com/docs/editor/extension-marketplace)。
没有复制第三方源码或测试输入，也没有把它们加入运行时依赖。

- Guardian 事件落盘现在默认是当前文件加两个轮转文件、每个最多 256 KiB；`eventLogMaxBytes` 和 `eventLogMaxFiles` 有硬上限，配置降低后会清理超出范围的旧归档。原始 Tool 参数仍只参与不可逆指纹，不进入事件文件。
- 恢复快照会把标记为敏感的条目和 `.env` 文件记录为 excluded，但不复制内容；恢复动作也不会覆盖这些文件。这样“可回滚”不会变成“把凭据复制进快照”。
- VS Code 的 Extension Bisect 只吸收“缩小搜索空间”的产品形状；当前 `plugin-bisect-plan` 仍只给人工执行顺序，拒绝自动切换 Git 工作树或 Profile。
- `dsh-fail-logger` 的去重/TTL 思路转化为本地日志保留门，而不是把失败正文持久化到 skill 或外部服务。

### `dsh-savepoint` 审计与吸收边界（2026-08-16）

用户所称的 `dsh-undo-savepoint` 对应公开仓库
[`ssipbss/dsh-savepoint`](https://github.com/ssipbss/dsh-savepoint)。本次审计基准为
`main` 提交 `9cf1524ff8135a2aed94c9c51128a4410d51017e`，仓库 LICENSE 为 MIT。
审计包含 `plugin/savepoint.host.src.js`、`plugin/savepoint.client.js`、
`plugin/persist-bundle/index.js`、`scripts/snapshot.ps1`、`scripts/restore.ps1` 和
`tests/run-tests.ps1`；没有将其作为依赖安装到本包，也没有复制其源码。

该项目与本包的关系不是“谁替代谁”，而是两个层次：

| 方面 | 当前 `dsh-plugin-debug` | `dsh-savepoint` 的独特价值 |
| --- | --- | --- |
| 普通配置恢复 | 已有 Profile/Workspace snapshot、known-good、rescue、SHA-256 和恢复 receipt | 基础 snapshot/restore 与本包已有能力重叠，不应再复制一套存储和入口 |
| 已知健康恢复 | known-good 默认冲突拒绝、自动恢复次数有界、保留失败插件 quarantine | 不是它的核心语义 |
| 单次插件变更回退 | 现有 repair 可以安全 quarantine 已归因的坏插件，但没有 before/after 事务配对 | 能用三路合并把一次插件安装的配置差异从当前状态中局部撤销，并保留后续变更 |
| DSH 原生 Session undo | rc.6 只有 append-only event log、`session/flush` durability barrier、`Session.fromRestore()` 和历史 `fork()`；未发现 `undo/savepoint/rewind` | 它也不能提供原生 Session 历史回退，主要处理 Profile 配置文件 |
| 独立恢复 | 已有 PowerShell recovery 入口，可在 Web 不可用时工作 | 独立恢复脚本和明确的故障现场保留体验值得借鉴 |

审计确认的可吸收设计形状：

- `before`/`after` 成对元数据，而不是只用自由文本 Label 推断变更关系；
- 恢复前 quarantine/rescue；
- JSON/文本三路合并、冲突保留当前状态并生成结构化报告；
- 恢复后 post-image hash 和 receipt；
- 手动/自动存档的生命周期和保留数量分层；
- DSH 无法启动时仍可使用的独立恢复入口。

审计确认的拒绝项：

- 候选脚本把 `.credentials.yaml` 复制到普通快照；本包继续默认排除 `.credentials*`、
  API key、Cookie、`.env*` 和 Session 正文，不因为兼容候选项目而扩大敏感数据面；
- Host/bundle 在沙箱拒绝后自动重试 `danger-full-access`；本包不自动绕过沙箱策略；
- sessions 只用路径/大小/修改时间摘要，不足以证明内容完整性；本包不会把这种摘要
  当成强一致性证明；
- 词法路径检查没有充分覆盖 junction/symlink/reparse point；后续若实现 surgical
  savepoint，必须沿用或加强当前 Recovery/Workspace 的 reparse-point 边界；
- 自动轮询、自动部署、snapshot 删除、`pnpm install --force`、停止进程和重启 Web
  都不属于首个安全 savepoint 的默认动作；
- 候选测试主要是 fixture PowerShell 脚本，不等于真实 Host、Client、bundle、真实
  Profile、权限竞争或真实任务恢复通过。

因此当前实现决策是：

1. 不直接吸收候选仓库，不引入其 `persist-bundle`，不自动安装到用户 Profile；
2. 不重复实现普通 snapshot/restore；继续以本包已有 Recovery、known-good 和 repair
   receipt 为底层；
3. 若确实需要“只撤销某一次插件安装”，再增加 Profile-only 的 `safe-savepoint`：
   同一 Profile 的 before/after 配对、allowlist、hash 冲突门、默认
   `CONFLICT`/`MANUAL_REVIEW`、显式 `-Force`、rescue 和 receipt；不得触碰 sessions、
   credentials、Workspace 或 `node_modules`；
4. 在增加多插件时间线、冲突、恶意路径、reparse point 和恢复后不变量测试前，不把
   该设计称为已生产支持；当前它是“设计吸收、代码暂不复制”。

### `dsh-hotswap` 审计与吸收边界（2026-08-16）

用户追加的 `dsh-hotswap` 不是一个唯一仓库。本轮用 GitHub 公共只读 API、公开
README 和文件树核对了两个同名项目；没有把任一项目安装到真实 Profile，也没有复制
源码或把它加入运行时依赖。

| 仓库 | 审计基线和公开信号 | 观察到的实现 | 风险与本项目决定 |
| --- | --- | --- | --- |
| [HongzhongL/dsh-hotswap](https://github.com/HongzhongL/dsh-hotswap) | `main` 提交 `86b17d39f36979aeb80e745349ebeeeca5ff6e0a`；npm/仓库版本 `0.1.1`；MIT；0 stars；没有 GitHub Actions，也没有测试目录 | JavaScript 发布入口完整，使用 `webServer`/`loader` 提供同源状态、启停、重启和重置路由；通过 Cordis `entry.update({ disabled })`、`entry._dispose`、`entry.refresh` 和 ESM cache eviction 尝试热启停/重载；还观察 Profile `package.json` 的 bundle 增删 | 设计完整但依赖内部 `_dispose`/`refresh`，缓存清理是 best-effort；POST 路由在绑定到 `0.0.0.0` 时没有额外鉴权；自动观察 Profile 并改写 `cordis.patch.yml` 会扩大变更面。只吸收保护名单、ancestor/runtime-only/`!!js` 检查、串行队列和 fail-closed 形状，不直接复制运行时动作 |
| [jarvan642/dsh-hotswap](https://github.com/jarvan642/dsh-hotswap) | `main` 提交 `a05afc945af5f7666d48c207cfaf3fffa4bcfd58`；1 star；没有发现许可证文件/元数据或 GitHub Actions；最近提交删除了包含 token 的 `.npmrc`，不读取也不输出历史内容 | TypeScript 源码、单元测试和 React 管理面板存在，但 GitHub 文件树没有 `lib/`；`package.json` 入口是 `lib/index.js`，又没有 `prepare`/`prepack`，从 GitHub 直接安装很可能没有可运行入口；服务层用 `execSync` 拼接 `npm install`/`npm uninstall` | 构建产物和发布协议不闭合；`source`/`name` 进入 shell 拼接的安装/卸载路径，存在命令注入风险；默认 Profile 路径/包管理器也不匹配本机 pnpm/DSH 约定。不能直接安装或吸收；若未来重新评估，必须先确认历史凭据已撤销、补齐构建产物/许可证/CI，并消除 shell 执行 |

#### 可吸收的设计形状

- 先做只读 capability probe：分别报告“能观察到插件清单”“Host 明确声明了运行时
  启停合同”“当前条目满足安全切换前置条件”；没有官方合同时输出
  `UNAVAILABLE`，不能因为看到了 `enabled` 字段就宣称可以启停。
- 保护 `webserver`、`connection`、`api-gateway`、`modules`、`typert*`、Web client
  和 Debug 自身等核心条目；同时检查 ancestor disabled、runtime-only entry、
  `!!js` 表达式和依赖关系。
- 如果将来确实实现显式 opt-in 的切换模块，所有操作必须进入串行队列；patch 写入沿用
  当前的 Profile containment、原子写、内容保留、冲突检测和 receipt 规则。
- UI 只能展示候选、保护原因、前置条件和回滚计划；不能把任意 npm/pnpm/shell
  命令、仓库地址或 Profile 路径交给模型或浏览器 POST 路由执行。

#### 当前明确不吸收的内容

- 不调用 Cordis 私有/半私有的 `_dispose`、`refresh`，不依赖 ESM cache eviction
  来证明代码已重新加载；除非 DSH 官方提供稳定、可测试的生命周期合同；
- 不监听 `package.json` 后自动安装/卸载/热挂载 bundle；不默认改写真实 Profile 的
  `cordis.patch.yml`；不在 `0.0.0.0` 暴露无鉴权的启停 HTTP API；
- 不把 `dsh-hotswap` 作为 `dsh-plugin-debug` 的依赖，也不把热切换悄悄并入当前
  observer-only Guardian。Guardian 的安全承诺继续保持：不终止任务、不停止进程、
  不重启 Host、不禁用插件、不修改 Profile。

#### 当前产品状态和后续门禁

当前版本没有热切换动作、POST 动作或自动 watcher；新增的
`plugin_hotswap_check` 只是只读 capability probe，和已有的 `pluginEnablement`
一样不会改变运行时。后续只有在用户明确开启独立 opt-in 模块，并且先具备以下
证据时，才考虑实现：官方 Host 生命周期 API 合同、核心保护/依赖图、disposable
fixture、恶意同源请求测试、真实 Profile dry-run、patch 冲突/回滚测试和切换后
post-image 验证。即使这些门禁通过，也要把“切换请求已接受”“模块已重新加载”“页面
已刷新”“业务任务仍可用”分成不同 verdict；不能用一个 `restart: ok` 代替生产可用性。

补充核对本包锁定的 DSH rc.6 runtime：其中已经包含
`@deepseek-ai/cordis-plugin-hmr@1.0.16`，公开类型声明提供 `ctx.hmr`、`getLinked()`
和 `registerConfig()`，Profile boot 还会在缺少 HMR service 时创建 `root: []` 的实例。
但该服务构造时要求 loader internals（`--expose-internals`），真正的 partial reload
仍在内部缓存、registry 和 fiber 生命周期上工作；这不是 `dsh-plugin-debug` 可以直接
调用的稳定“插件替换合同”。因此当前 probe 只报告“观察到官方 HMR”，不会调用它，
也不会因为 HMR 存在而把 verdict 提升为 `SUPPORTED`。

## 2026-08-17 真实 pinned rc.6 Web、inventory 与 ToolRuntime 复核

本次使用锁定的 `@deepseek-ai/dsh@0.1.0-rc.6`，在隔离的临时 runtime、Profile、workspace
和 state 目录中启动；没有访问真实的 `C:\Users\Zz\.dsh\profiles\web`，没有读取或输出
凭据。临时 DSH 子进程在复核结束后已停止。下表故意把“Web 启动”“Host 看到插件”“工具
真实 dispatch”“有业务历史”拆成四个不同的证据等级：

| 检查项 | 结果 | 当前证据 | 不能推出的结论 |
| --- | --- | --- | --- |
| 真实 Web 启动 | `PASS` | `http://127.0.0.1:31989/` 和 `http://127.0.0.1:31990/` 返回 HTTP 200，`webIsDsh=true`，supervisor 为 `healthy` | 不能推出真实业务 Session 已创建或历史已读取 |
| 真实 Host/API/inventory | `PASS` | `host.describe`、`session.list`、`pluginInventory/list` 成功；inventory 共观察到 134 个条目、`failedCount=0`；其中 `dsh-plugin-debug` 为 `enabled=true`、`fiberPhase=active` | 不能推出每个插件功能都已在真实业务数据上验证 |
| 三个 Debug 工具注册与 dispatch | `PASS` | 三个 schema 都报告 `registered=true`，并经真实 `ToolRuntime.execute` 调用，均 `isError=false` | 不能把工具 schema/dispatch 通过写成完整业务回归通过 |
| 有数据 Session 的报告 | `PASS`（失败路径） | 真实隔离 Profile 读取 1 个 Session、15 条事件，报告识别 1 个失败回合、0 Tool Call、0 Token、`¥0.0000`；请求以 `MISSING_CREDENTIAL` 失败闭合 | 不能声称已经验证成功模型、真实 Token/费用账单、模型 Tool Call 或生产 Profile |

真实 dispatch 的逐项结果如下：

- `plugin_check`：dispatch 成功，`action=schema` 返回插件检查 schema；
- `plugin_hotswap_check`：dispatch 成功，但按安全设计返回
  `verdict=UNAVAILABLE`、`execution=NOT_ATTEMPTED`、`actualHotSwap=false`。当前没有权威、稳定、
  带版本的 Host 生命周期合同，因此不能把“能观察到 HMR”写成“可以热切换”；
- `dsh_agent_report`：dispatch 成功，返回 `status=PASS`、`source=SessionQuery`，读取 1 个
  Session、使用 15 条事件，识别 1 个失败回合、0 Tool Call、0 Token、费用 `¥0.0000`，
  并明确没有执行命令、没有修改数据。报告中的失败来自 `MISSING_CREDENTIAL`，这是有数据
  的真实失败路径证明，不是成功模型或真实账单证明。

### `dsh-whale-report` 0.4.0 的确定性 Agent 报告吸收结果

对 [SenmuuuuW/dsh-whale-report](https://github.com/SenmuuuuW/dsh-whale-report) 的吸收范围已经
收敛为“吸收确定性报告引擎和报告产品形状，独立实现，不引入上游运行时依赖”。当前包中的
`dsh_agent_report` 已覆盖以下只读信息：Session/turn/step、user/assistant message、
input/output/cache/reasoning token、model/provider、本地内置费用估算、Tool Call 与 Tool
error、turn failure、abort、interruption、retry burst、危险操作线索、secret pattern 类型、
成本最高的 Session、数据覆盖范围、读取失败和资源上限。

报告的边界也属于功能的一部分：费用始终标记为“内置估算价，非账单”；读取最多 500 个
Session、单个 Session 最多 100,000 条事件、总计最多 1,000,000 条事件；部分读取或触及
上限返回 `PARTIAL`，没有可用 Session 查询服务返回 `UNAVAILABLE`。报告只输出脱敏后的
统计和风险类型，不输出原始命令、Tool 错误正文、密钥原文或完整 Session ID。

明确拒绝吸收的上游边界：不读取 `.credentials.yaml`、`.env`、`DEEPSEEK_API_KEY` 或其他
凭据；不探测余额；不联网请求余额或抓取价格；不复制完整 Web UI；不把上游作为运行时依赖；
不复制上游 `rm -rf lib` 构建脚本。当前代码中的 `rm -rf` 只作为 Session 事件文本的风险
识别线索或合成测试输入，不交给 shell 执行，也不代表 Debug 插件执行过该命令。

2026-08-17 的公开复核还确认：上游 `src/balance.ts` 仍会读取 DSH
`.credentials.yaml` 中的 `DEEPSEEK_API_KEY` 并请求余额接口，`src/pricing.ts` 仍会联网抓取官方价格页，
而 `package.json` 的构建脚本仍包含 `rm -rf lib`。因此本项目继续只保留本地确定性报告和内置估算价，
不把这些副作用误当成“报告功能”打开。

### 默认不开 Crash Guard 的 inventory 导入修复

本轮还修复了 `tools/Start-DSH.ps1` 的默认启动路径：此前未传 `-EnableCrashGuard` 时，
KeepAlive 监督器仍调用 `Get-DshPluginInventory`，但 inventory 适配模块只在 Crash Guard
路径导入，导致真实运行时可能出现“找不到 `Get-DshPluginInventory`”。现在由
`Ensure-DshGuardModule` 始终加载只读 inventory 适配模块；只有显式开启 Crash Guard 时才创建
Guard 状态、隔离插件或执行重启逻辑。模块不可用时会返回明确的 inventory unavailable 降级原因。

修复后的默认启动 loopback/supervisor 回归为：`result=PASS`、
`scenario=default-launcher-inventory-without-crash-guard`、`bootCount=1`、`webReady=true`、
`supervisorStatus=healthy`、`supervisorReason=web-and-plugin-inventory-healthy`、
`guardStateCreated=false`。这证明默认路径的模块导入回归已闭合；它仍然是本地受控 runtime
fixture 证据，不等同于真实业务 Session 或真实历史报告证据。

### `session.create` 的当前隔离复核与历史外部观察

在当前全新的隔离 rc.6 Profile 中直接调用 `session.create(agentPreset=minimal)` 已通过，
创建后再次调用 `session.list` 能看到 1 个 Session。这个预检没有调用 `session.prompt`、
没有读取凭据、没有产生模型请求或费用；因此它证明了当前隔离运行时可以创建最小 Session，
但不证明成功模型、真实账单或模型 Tool Call。

此前另一个外部 DSH 实例曾返回 `agent-preset-invalid`，核心错误是
`prompt section "deployment:persona" is already registered`。该现象应作为外部实例的历史
运行观察保留，不能写成所有 Profile 必然失败，也不是 `dsh_agent_report` 产生的错误；临时
overlay 没有进入仓库，也不应被当作生产修复。

## 2026-08-18 发布后隔离与用户 Profile 复核

本次复核没有改变源码、Profile manifest、patch、远端或发布标签。先在当前 `main` 运行
`npm run check`：生成物 10 项、JavaScript 35 个文件和 3 个 workflow 的 13 个 external
uses 均通过，95/95 Node 测试通过，`git diff --check` 通过，工作树保持干净。

随后对本机已有的 `C:\Users\Zz\.dsh\profiles\web` 做了一次明确的只读启动兼容检查。使用
随机 loopback 端口、`-NoInstall -NoPluginInstall -NoBrowser -NoErrorDialog`，没有调用
`session.prompt`、没有创建 Session、没有安装候选插件、没有读取凭据。结果如下：

| 检查项 | 结果 | 证据和边界 |
| --- | --- | --- |
| 用户现有 `web` Profile 启动 | `PASS` | Web HTTP 200，`host.describe` 成功，Host inventory 观察到 134 条，`dsh-plugin-debug` active |
| Profile 是否被改写 | `PASS` | 启动前后 `package.json` 和 `cordis.patch.yml` SHA-256 相同；没有 `-Install` 或 `-PluginInstall` |
| 模型/凭据边界 | `PASS` | `modelRequests=false`；没有读取、打印或上传凭据，也没有发送模型请求 |
| 进程处置 | `PASS` | 只停止本次启动且由精确 PID 回执识别的进程；loopback 端口已释放，临时 state 保留在明确的 Temp 路径作为证据 |

这证明当前用户 `web` Profile 能加载 Debug 并通过启动层兼容检查；它不证明该 Profile 的
成功模型请求、真实账单、第三方插件共存或生产 hotswap。`debug`、`web` 和
`provenance-only` 当前都链接了 Debug；没有任何一个当前用户 Profile 被安装 hotswap、
Whale 或独立 `dsh-plugin-check` 候选。

### 第三方候选的可复现性复核

继续使用 `C:\Users\Zz\AppData\Local\Temp\dsh-external-research-20260817-a` 的研究副本，
没有补装依赖、没有执行候选的 DSH runtime 变更：

- `dsh-plugin-check` 的 `npm run typecheck` 通过，Vitest `81/81` 通过；它与 Debug 同装
  时注册同名 `plugin_check`，因此继续保留 Debug 的单一实现。
- `dsh-whale-report` 的 `lib/index.js` 语法可解析，但研究副本没有声明的 `zod`，所以
  没有 import 或启动它；不把静态语法通过写成运行时兼容通过。
- Hongzhong `dsh-hotswap` 的 `index.js`/`client.js` 语法通过；Jarvan 候选的
  `package.json.main=lib/index.js` 在仓库中不存在，且没有 `lib` 构建产物。
- Debug 的严格 `plugin_hotswap_preflight` 对 Hongzhong 和 Jarvan 均返回
  `verdict=MANUAL_REVIEW`、`networkAccessed=false`、`commandsExecuted=false`、
  `executesPluginCode=false`、`targetMutated=false`、`actualHotSwap=false`。
  Hongzhong 暴露 shell/包管理器、私有生命周期、缓存清理、patch/watcher、非原子写入、
  缺测试和 CI；Jarvan 还暴露未鉴权控制面、缺回滚和缺核心保护。

这些结果足以支持“候选不能直接进入生产 Profile”的维护结论，但不把静态 finding 当作
漏洞利用证明，也没有调用任何候选的 POST 热切换接口。

## 未宣称完成的部分

- DSH 原生 durable rewind 事件在当前实际 rc.6 上没有被验证，因此本项目不能声称可以无损删除或重写对话历史。
- 旧记录中关于真实端口 `3081` 的 Tool Call 表述不再作为当前证据：本轮没有在缺少明确 Session ID 时读取该端口上的业务 Tool Call，也没有把旧端口/旧上下文与 2026-08-17 的 rc.6 复核混用。Host 配置里的 `danger-full-access` 不是 Tool 成功证据；当前能确认的只是上文列出的三个 Debug 工具经真实 `ToolRuntime.execute` dispatch 成功。
- 成功 provider/model 响应、真实 Token/费用账单、模型生成 Tool Call、生产第三方安装、生产 hotswap 和跨平台运行仍未验证；当前已经验证的是有数据但失败的 `SessionQuery` 报告路径。真实模型验证必须使用临时隔离 Profile，并取得明确的 provider、model、费用上限和网络/Session 授权。
- 当前真实实例的运行时模型证据是 `deepseek-official/deepseek-v4-flash`；`gpt-5.6-sol` 只有在 Session history/request context 观察到时才会被报告为运行中。
- zstd Session 文件会被识别并标记为 `not-decoded`，不会假装已解码；后续可以在检测到本机可用解码器时增加显式 opt-in 读取。

## 检索边界

本轮先尝试了联网搜索服务，但匿名额度已耗尽；随后使用 GitHub 公共只读 API 核对仓库元数据、README 和文件树。没有使用 GitHub 密码、Token 或 API key，也没有向外部服务上传本地代码、Session、Cookie、Tool 参数或诊断文件。
