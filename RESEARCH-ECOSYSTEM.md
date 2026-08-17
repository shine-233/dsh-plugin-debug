# DSH Debug Ecosystem Research

研究日期：2026-08-17（中国标准时间）

这份记录说明本项目为什么吸收某些能力、拒绝某些能力，以及检索结果
的边界。它不是“扫描 GitHub 全部插件”的声明，也不是第三方代码的复制
清单。本轮使用 GitHub 的公开只读 API 和公开仓库页面核对名称、README、
文件树、许可证线索和实现形状；对明确进入直接审计的候选只在 `tmp/` 下做了
临时浅克隆和本地测试。没有上传本机源码、Session、Cookie、日志、Tool 参数
或诊断文件。

## 检索边界

本轮的实际目标是寻找和 DSH Debug Plugin 直接相关的 doctor、health、trace、
recovery、plugin manager、bisect 和 observability 方案。查询结果经过人工
筛选，不把搜索结果数量当成生态完整性证明。没有把没有明确许可证的代码复制
进本项目，也没有把任何第三方仓库加入运行时依赖。

下面这组初筛仓库只读取 GitHub 公共 API 元数据和公开 README/文件树；没有做
全站关键词扫描。`dsh-savepoint` 和 `dsh-plugin-check` 属于后续明确选定的
直接审计对象，另在 `tmp/` 中按本记录的范围做了临时浅克隆：

```powershell
$repos = @(
  'zoahdev/dsh-plugin-doctor', 'chenw2759-wq/dsh-plugin-healthcheck',
  'gordonlu/dsh-context-lens', 'wellorbetter/dsh-plugin-window-stats',
  'PangYiMing/dsh-bisect-debug', 'linyp/dsh-plugin-langfuse',
  'LX2000WASD/dsh-web-plugin-manager', 'awesome-dsh-plugin/awesome-dsh-plugin'
)
foreach ($repo in $repos) { gh api "repos/$repo" }
```

下面的许可证是 GitHub API 在 2026-08-16 返回的 `license.spdx_id` 观察值，
不是法律意见，也不是对第三方代码的再许可。正式发布前仍需读取每个仓库的
`LICENSE` 全文、版本和作者声明；本包不复制这些仓库的源码。

## 核对过的公开项目

### 2026-08-16 GitHub 搜索复查

本次用 GitHub 公共仓库搜索复查了 `dsh debug plugin`，结果中出现了几类值得区分的项目：

- [yefei124/superpowers-workflow](https://github.com/yefei124/superpowers-workflow)：偏开发流程引导（头脑风暴、计划、TDD、调试和 Markdown 导出），不是运行时诊断器；可借鉴新手引导，但不应把工作流提示当成故障证据。
- [PangYiMing/dsh-bisect-debug](https://github.com/PangYiMing/dsh-bisect-debug)：专门做代码/边界/commit 二分；本项目继续只输出安全候选计划，不自动切换工作树或执行 reset。
- [akira399/dsh-guardian](https://github.com/akira399/dsh-guardian)：任务循环、递归和中断保护；本项目已用独立实现吸收 observer-only 形状，并继续禁止任务/进程终止。
- [zoahdev/dsh-plugin-doctor](https://github.com/zoahdev/dsh-plugin-doctor) 与 [jorinyang/dsh-doctor](https://github.com/jorinyang/dsh-doctor)：分别强调插件打包/安装门禁与环境/端口/Profile 诊断；本项目已具备对应的离线边界检查和只读 doctor，但真实 fresh-profile/生产 Web readiness 仍单独标注。
- [jkrandom-sudo/dsh-ci-doctor](https://github.com/jkrandom-sudo/dsh-ci-doctor)：把 Actions 失败转换为结构化诊断卡和重复失败账本；本项目本轮先打开 Dependabot、CodeQL 和定期 CI，不引入常驻 GitHub watcher 或外部 telemetry。
- [dongsheng123132/harness-doctor](https://github.com/dongsheng123132/harness-doctor)：只读 support bundle 和 allowlist 修复；本项目保留 metadata-only repro export，仍拒绝无 allowlist 的完整目录打包。

这些项目的仓库描述、默认分支、许可证元数据和更新时间通过 GitHub 公共 API 在本日期读取；它们不是本项目的运行时依赖，也没有复制第三方源码。搜索结果不能证明生态完整，功能结论仍以各仓库当前 README/代码为准。

| 项目 | SPDX 元数据 | 观察到的能力 | 本项目的吸收或拒绝决定 |
| --- | --- | --- | --- |
| [zoahdev/dsh-plugin-doctor](https://github.com/zoahdev/dsh-plugin-doctor) | MIT | manifest/patch/entry/files 检查、fresh-profile 安装、BOM、大文件、入口副作用、环境检查、JSON CI 报告 | 吸收分层 doctor、fresh-profile 验证和可机器读取报告；本项目仍以离线、只读、边界明确为默认 |
| [omdsh-dev/dsh-plugin-check](https://github.com/omdsh-dev/dsh-plugin-check) | MIT；审计基线 `397aa26df241aca530aa65a08484a664f7d555ad` | 按 registry/skill/collection/bundle 分流，manifest/patch/build 检查，Profile Bundle 安装提示，报告聚合和 `plugin_check` 注册；仓库自带 73 个 Vitest 用例但没有 CI | 已吸收规则形状和负例测试：当前 `plugin_check` 保持单一注册、零额外运行时依赖，并加入形态分流、路径/junction 围栏、patch 核心 row 保护、TS 构建陷阱和 lifecycle 静态提示；不复制其宿主 peer 导入、`gh api`/Git hub 查询或 basename 收录判断 |
| [chenw2759-wq/dsh-plugin-healthcheck](https://github.com/chenw2759-wq/dsh-plugin-healthcheck) | MIT | L0 静态检查、L1 composition、L2 isolated boot、恶意代码扫描、safe repair/rollback | 吸收分层健康门和安全修复方向；不自动改 Profile，不自动处理核心包，无法归因时 fail-closed |
| [gordonlu/dsh-context-lens](https://github.com/gordonlu/dsh-context-lens) | MIT | metadata-only context profiling、tool schema fingerprint、cache delta、replay consistency | 吸收 metadata-only trace/profile 和 change-first 诊断；拒绝持久化原始请求、Tool 参数和结果正文 |
| [wellorbetter/dsh-plugin-window-stats](https://github.com/wellorbetter/dsh-plugin-window-stats) | MIT | session overview、token/context pressure、成本估算、本地只读分析 | 吸收资源压力和窗口统计的只读形状；当前不宣称可从没有 Session ID 的真实实例读取 Tool Call |
| [SenmuuuuW/dsh-whale-report](https://github.com/SenmuuuuW/dsh-whale-report) | MIT；`main` 当前审计文件提交 `966c80f5c2bfb150b0318e3acb72338780f6b8e9`；版本 `0.4.0`；18 stars | Session/Token/Tool Call/失败/重试/危险命令/本地费用估算/确定性洞察/报告 UI；另含余额探针、凭据读取和 DeepSeek 网络请求；构建脚本仍使用 `rm -rf lib`，CI 只跑 Ubuntu | 吸收确定性报告引擎和“覆盖范围/估算/风险线索”产品形状；当前 `dsh_agent_report` 不复制完整 UI、余额探针、凭据读取、网络价格/余额请求、上游依赖或 Unix-only 构建脚本；`rm -rf` 只作为文本检测规则，不执行 |
| [PangYiMing/dsh-bisect-debug](https://github.com/PangYiMing/dsh-bisect-debug) | MIT | 代码、边界和 Git commit 二分定位 | 已吸收为 `plugin-bisect-plan` 的只读插件候选排序、证据摘要和人工步骤；不自动切换 Git 工作树、不执行命令、不修改 Profile |
| [linyp/dsh-plugin-langfuse](https://github.com/linyp/dsh-plugin-langfuse) | MIT | OpenTelemetry/Langfuse 外部导出 | 拒绝：会扩大网络出口，并可能泄漏原始内容；当前包只做本地 metadata-only evidence |
| [LX2000WASD/dsh-web-plugin-manager](https://github.com/LX2000WASD/dsh-web-plugin-manager) | MIT | 运行时启停、依赖/冲突/健康检查 | 吸收只读 inventory 和明确第三方隔离；拒绝把本项目变成 marketplace 或任意运行时管理器 |
| [awesome-dsh-plugin/awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin) | CC0-1.0 | 生态索引和插件发现 | 仅作为发布前人工审查入口，不作为运行时依赖 |
| [jorinyang/dsh-doctor](https://github.com/jorinyang/dsh-doctor) | MIT（包内账本已核对） | 环境/端口/Profile/HTTP/disk 检查，safe/deps/full 修复 scope，LIFO journal，Web 不可用时的 CLI | 吸收只读 doctor、独立 Host 入口和 receipt 思路；拒绝 full process cleanup、shell 拼接和宽泛 repair |
| [lire1131/dsh-undo-plugin](https://github.com/lire1131/dsh-undo-plugin) | 本轮未重新核对 | 配置快照、undo/redo、离线 CLI/GUI、启动异常横幅 | 已有 snapshot/restore、Crash Guard 和页面通知；不复制其 GUI 或包加载方式 |
| [PerryLink/dsh-checkpoint-rewind](https://github.com/PerryLink/dsh-checkpoint-rewind) | 本轮未重新核对 | 变更前 checkpoint、三阶段事务、配额、恢复日志、Session fork | 吸收 checkpoint/receipt 的安全形状；真实 durable rewind 事件未在 DSH rc.6 验证，因此不伪造该能力 |
| [BiBoyang/dsh-eval-harness](https://github.com/BiBoyang/dsh-eval-harness) | 本轮未重新核对 | 隔离 workspace/session、JSONL trace、baseline PASS/WARN/FAIL 门禁 | 已有脱敏 Trace/Eval/baseline；zstd 解码和真实 headless LLM 回归仍标为未完成 |
| [akira399/dsh-guardian](https://github.com/akira399/dsh-guardian) | MIT；本轮只读复核的 `main` 提交为 `5bf7ef3ad56d5e0b78e40071ac99d94b697e468b` | 插件预检、重复 Tool Call 循环、Agent/Workflow 递归、中断感知、`safeToRestart` 和实际安全重启助手 | 单包已独立实现预检、运行时循环/递归观察、冷却提示、事件上报和只读状态检查；不复制源码，不并入实际重启脚本 |
| [jkrandom-sudo/dsh-ci-doctor](https://github.com/jkrandom-sudo/dsh-ci-doctor) | 本轮用 GitHub 公共 API 只读核对 | 只读 Actions watch、失败签名归一化、重复失败 ledger | 吸收失败签名和可追踪 ledger 的数据形状；当前只在 CI artifact/receipt 中保留本次运行元数据，不创建常驻 watcher 或外部服务 |
| [tree201/dsh-capability-inspector](https://github.com/tree201/dsh-capability-inspector) | 本轮用 GitHub 公共 API 只读核对 | 能力矩阵、workspace/session health、单项失败降级 | 吸收分层 capability matrix 和“单项失败不拖垮整份报告”；未知 Host 能力仍输出 `UNAVAILABLE`，不猜测可用 API |
| [dongsheng123132/harness-doctor](https://github.com/dongsheng123132/harness-doctor) | 本轮用 GitHub 公共 API 只读核对 | 只读 support bundle、schema 版本、显式 allowlist 修复、无 `fix-all` | 吸收 schema/allowlist/support-bundle 边界；拒绝全自动修复、任意文件打包和隐式 Profile 变更 |
| [ssipbss/dsh-savepoint](https://github.com/ssipbss/dsh-savepoint) | MIT；本次直接审计 `main` 提交 `9cf1524ff8135a2aed94c9c51128a4410d51017e` | 安装前/后存档、启动基线、自动变更检测、quarantine、三路 surgical rollback、独立 PowerShell 恢复 | 只吸收 before/after 配对、局部回退、冲突报告、rescue/quarantine 和独立恢复的设计形状；不复制源码，不备份 `.credentials.yaml`，不自动升级 `danger-full-access`，不自动重建依赖，也不把其 fixture 测试当作真实 DSH 证明 |

## 已经进入单包的能力

- provenance、pointer evidence、client/Host diagnostics 和 plugin inventory；
- plugin health、context doctor、security audit、resource pressure；
- incident capture、correlation、trace/eval/profile/autopsy 和 baseline；
- workspace/Profile snapshot、known-good checkpoint、recovery；
- constrained self-repair、receipt、pre-image/post-image hash 和 rollback conflict fail-closed；
- one-click launcher、Supervisor、Crash Guard、启动冲突隔离和 Workbench；
- `plugin-bisect-plan`：根据脱敏 inventory、失败证据和 Profile manifest 生成 `safe`、`protected`、`ambiguous` 候选及人工复核顺序；
- 启动后页面通知，以及只在 Host 明确声明 `no-tools` planner 时创建隔离诊断会话。
- observer-only `dsh-guardian`：运行时循环/递归/中断检测、一次性引导、脱敏事件上报、只读 `safeToRestart` 状态和有界事件日志轮转；它不终止任务、不杀进程、不重启 Host、不禁用插件。

## 明确不引入的边界

本项目不恢复 `dsh-plugin-store`，不创建新的 marketplace，不后台上传遥测，
不把普通 `session.create` 误称为 no-tools Session，不自动禁用 DSH 核心包，
不执行任意模型生成的 command/script/path/url，不做无限重启，不清理任意进程，
不把真实 Profile、日志、凭据、Cookie、Tool 参数、结果正文或完整路径写进诊断
Session。无法明确归因、缺少 evidence、目标是核心包或 receipt 发生冲突时，
操作保持 `UNAVAILABLE`、`FAIL` 或 `ROLLBACK_CONFLICT`。

## 后续候选能力

1. 在 DSH 官方提供稳定 no-tools planner 和 durable rewind 事件后，再增加对应的
   capability probe 和独立回归测试。
2. 在用户明确指定工作树和恢复点、且有独立恢复门禁后，再考虑 code/commit bisect；
   当前 `plugin-bisect-plan` 只处理插件 inventory/evidence，不自动 reset 或删除文件。
3. 在 fresh Profile 流程稳定后增加 composition 与 isolated-boot 两级发布门，
   并把结果写入 JSON，而不是把“静态通过”说成生产运行通过。
4. 只有用户明确开启、并且存在脱敏 schema 和本地留存策略时，才考虑外部
   OpenTelemetry 导出；默认保持关闭。

## 2026-08-16 在线复核与本轮吸收

本轮又用 GitHub 公共 REST API 读取了仓库元数据和公开 README，没有使用令牌，
也没有上传本机文件。API 返回的项目描述、默认分支和许可证线索用于确认研究
对象仍然存在；许可证字段不是法律意见，仍不能替代逐仓库阅读 LICENSE。

| 公开项目/文档 | 本次直接看到的信号 | 本项目的具体决定 |
| --- | --- | --- |
| [akira399/dsh-guardian](https://github.com/akira399/dsh-guardian) | README 明确记录滑动窗口循环、Agent/Workflow 递归、中断和 `safeToRestart`；GitHub API 返回 MIT | 已独立实现这些 observer-only 观察边界；本轮继续吸收它暴露出的“长期事件文件必须有界”问题，新增 `eventLogMaxBytes`/`eventLogMaxFiles` 轮转和旧归档清理；不复制源码或实际重启脚本 |
| [zoahdev/dsh-plugin-doctor](https://github.com/zoahdev/dsh-plugin-doctor) | README 说明 manifest/patch/entry、`npm pack --ignore-scripts`、临时 `DSH_HOME`、fresh-profile、BOM、大文件、入口检查和 Web readiness/rollback，并提供 JSON CI 输出；API 返回 MIT | 当前单包已有离线 repository check、plugin preflight、dependency graph、fake offline install、publication verifier 和 standalone 测试；吸收 pack 隔离、分层 readiness 和 rollback receipt 的设计形状，但不把真实 DSH Web readiness 或 runtime/native 隔离冒充已验证，也不把 DSH 官方尚未提供的 `dsh plugin check` 入口冒充成已存在 |
| [jorinyang/dsh-doctor](https://github.com/jorinyang/dsh-doctor) | README 将诊断、分级修复、LIFO undo 和运行时服务分开，并保留 Web 不可用时的 CLI 方向；API 返回 MIT | 保留只读 doctor、receipt、known-good 和显式恢复边界；恢复快照现在明确排除 `.env`/敏感内容，回滚不会覆盖它们 |
| [PangYiMing/dsh-bisect-debug](https://github.com/PangYiMing/dsh-bisect-debug) | README 提供代码、边界和 Git commit 三种二分，并要求干净工作树、退出码和显式 reset | 已吸收为只读 `plugin-bisect-plan` 的 inventory/evidence 计划；当前没有验证真实代码/边界/commit 二分，不自动切换工作树、reset、删除文件或执行用户命令 |
| [Areium/dsh-fail-logger](https://github.com/Areium/dsh-fail-logger) | README 说明只记录 `isError=true` 的 Tool failure，做去重、计数、确定性排序、TTL 清理和脱敏；API 返回 MIT | 吸收“失败证据应可控留存”的设计形状，但不把原始失败正文写入 skill；Guardian 事件只保存指纹/类别，并以有界文件轮转替代无限追加 |
| [VS Code Extension Bisect](https://code.visualstudio.com/docs/editor/extension-marketplace) | 官方文档把 Extension Bisect 定义为通过启停扩展缩小问题范围 | DSH 的 `plugin-bisect-plan` 保留同样的缩小搜索空间思路，但使用安全候选、保护核心包和人工步骤；不在用户工作树上自动做破坏性切换 |
| [jkrandom-sudo/dsh-ci-doctor](https://github.com/jkrandom-sudo/dsh-ci-doctor) | 只读 Actions 失败签名、重复失败 ledger 和诊断输出 | 吸收失败签名归一化和 ledger 字段；当前只发布单次 CI 的 machine-readable artifact，未实现持久远端 ledger 或后台 watcher |
| [tree201/dsh-capability-inspector](https://github.com/tree201/dsh-capability-inspector) | 能力矩阵、workspace/session health，以及单项失败降级 | 吸收 capability matrix/report degradation 形状；未知或缺失 Host API 仍保持 `UNAVAILABLE`，不伪造 runtime readiness |
| [dongsheng123132/harness-doctor](https://github.com/dongsheng123132/harness-doctor) | support bundle schema、显式 allowlist 修复、默认没有 `fix-all` | 吸收 support-bundle schema 和显式 allowlist 原则；未验证完整 bundle 兼容性，不允许任意路径、凭据或原始 Session 内容进入导出 |
| [ssipbss/dsh-savepoint](https://github.com/ssipbss/dsh-savepoint) | `main` 当前提交 `9cf1524ff8135a2aed94c9c51128a4410d51017e`；仓库 LICENSE 为 MIT | 真实用户故障时间线的产品抽象：`before`/`after` 成对快照、当前现场先隔离、JSON/文本三路合并、冲突保留和独立恢复入口 | 当前 `dsh-plugin-debug` 已覆盖普通 Profile/Workspace snapshot、known-good、rescue、哈希和 `ROLLBACK_CONFLICT`；不再造一套普通 snapshot/restore。若补 savepoint，只增加 Profile allowlist 上的事务元数据和 fail-closed surgical 语义，并加入真实安全不变量测试 |
| [HongzhongL/dsh-hotswap](https://github.com/HongzhongL/dsh-hotswap) | `0.1.1`、MIT、`86b17d39f36979aeb80e745349ebeeeca5ff6e0a`；JavaScript 入口完整；同源启停/重启/重置路由；无 Actions、无测试目录 | 吸收核心保护、ancestor/runtime-only/`!!js` 检查、串行队列和分层 verdict；拒绝内部 `_dispose`/`refresh`、ESM cache eviction、自动 watcher、无额外鉴权的远程启停和默认 Profile patch 写入 |
| [jarvan642/dsh-hotswap](https://github.com/jarvan642/dsh-hotswap) | `a05afc945af5f7666d48c207cfaf3fffa4bcfd58`；1 star；未发现许可证或 Actions；最近提交删除含 token 的 `.npmrc`；源码有测试但没有 `lib/`，入口却指向 `lib/index.js`，无 `prepare`/`prepack` | 不吸收；构建/发布不闭合，历史凭据需先确认撤销，`execSync` 拼接 npm 安装/卸载扩大命令注入面，且 npm/Profile 路径不符合本包的 pnpm/DSH 约定 |

本轮没有把“看过这些项目”写成“已经完成生产兼容”。真正新增到代码的是 Guardian
事件日志的有界轮转/过期归档清理、恢复快照的敏感文件排除，以及现有
`plugin_check` 的离线仓库形态/路径/patch/构建规则；这些都有对应回归断言。pack
隔离安装、真实 DSH Web readiness、runtime/native 模块隔离、完整
support bundle、持久 CI ledger、网络导出、常驻 watcher、自动 Git bisect、durable
rewind 和模型自行执行修复仍保持明确的未吸收或未验证状态。

### `dsh-plugin-check` 直接审计结论（2026-08-16）

本次对照仓库是 [omdsh-dev/dsh-plugin-check](https://github.com/omdsh-dev/dsh-plugin-check)，
审计基线为 `397aa26df241aca530aa65a08484a664f7d555ad`，许可证为 MIT。临时副本在
`tmp/dsh-plugin-check-review` 中完成了 `npm ci --ignore-scripts`、`npm run check`：
typecheck、73 个测试和 build 均通过。该结果只证明候选副本的离线构建链通过，不能证明
真实 DSH Profile、Hub 或生产模型任务已经通过。

候选项目的高价值部分是把插件仓库先分成 registry、skill、collection、bundle/tool-bundle，
再分别检查清单、patch、构建产物和标准 Profile Bundle 安装文档；它还覆盖了 TypeScript
扩展名导入、`rewriteRelativeImportExtensions`、产物残留 `.ts`、重复 row id、核心 row
覆盖和固定格式报告。这些规则已经以当前单包的 JavaScript/零额外依赖实现进入
`packages/dsh-plugin-debug/src/repository-check.js`，并增加了路径逃逸、patch section、
registry/skill/collection 和 TS build-trap 回归测试；重新注册第二个 `plugin_check` 没有必要，
也会产生同名工具冲突。

明确拒绝原样吸收的部分：

- 候选入口直接导入 `@deepseek-ai/cordis` 和 `@deepseek-ai/dsh-tools`，所以“零依赖”只表示
  没有额外 YAML/semver 业务库，并非可脱离宿主的独立零依赖程序；当前单包继续用已有的
  `defineTool` 适配层，避免把宿主 peer 变成强运行时依赖；
- Hub 检查会执行 `gh api` 和 `git remote`，远端 catalog 失败时返回 `skipped`，且源码只按
  repository basename 匹配，不能作为 owner/repo 精确的发布门禁；当前报告显式输出
  `hub.status=skipped`，不联网、不读取本机 GitHub 登录态，也不把未知收录状态写成 PASS；
- 候选仓库没有 `.github/workflows`，README 里写的测试数量 `38` 与当前静态统计的 73 个
  `it(...)` 不一致；本项目的 CI 仍以 fresh-clone、发布边界和真实退出码为准；
- 候选 patch 解析是受限的行级 YAML 近似，不等同于完整 YAML schema；当前实现也只承诺
  可验证的 section/id/name/config 子集，不宣称能验证所有 YAML 标量、重复键或官方完整
  `PatchOptions` 语义。

因此最终选择是“吸收规则与测试，不吸收候选运行时和 Hub 网络行为”。

### `dsh-savepoint` 直接审计结论（2026-08-16）

本次对照仓库是 [ssipbss/dsh-savepoint](https://github.com/ssipbss/dsh-savepoint)，
用户所称的 `dsh-undo-savepoint` 对应这个公开项目。审计基准为 `main` 提交
`9cf1524ff8135a2aed94c9c51128a4410d51017e`；许可证为 MIT。检查范围包括
Host/Client/bundle、独立 PowerShell 脚本、测试和文档，没有把它加入运行时依赖，
也没有复制第三方源码。

它最值得吸收的不是普通“备份文件”实现，而是一次可解释的变更事务：

- 安装插件前后分别保存 `before`/`after`，使一次变更有明确边界；
- 恢复前先把当前状态放入 quarantine/rescue，保留故障现场；
- 通过 JSON/文本三路合并，只尝试撤销目标安装，冲突保留当前内容并报告；
- DSH 无法启动时仍可使用独立 PowerShell 恢复入口；
- 用快照 ID、相对路径、哈希和轮转策略限制恢复范围。

但本次审计也确认了不能直接吸收的边界：

- `scripts/snapshot.ps1` 把 `.credentials.yaml` 复制进普通快照，当前实现没有加密或
  明确的凭据 ACL；本项目继续默认排除 credentials、API key、Cookie 和 Session 正文；
- Host/bundle 在沙箱拒绝后会尝试 `danger-full-access`，本项目不接受自动权限升级；
- sessions 生产摘要主要是路径、大小和修改时间，不能等同于内容级完整性证明；
- 路径校验没有充分证明 Windows junction/symlink/reparse-point 边界；
- 可选 `pnpm install --force`、停止进程、重启 Web 和 snapshot 删除都超出首个安全
  savepoint 的必要范围；
- 测试主要直接调用两个 PowerShell 脚本和合成 DSH 家目录，没有证明真实 Host、Client、
  持久化 bundle、真实 Profile、权限、重启或生产任务恢复。

因此当前决定是：

1. 不把 `dsh-savepoint` 作为运行时依赖，不把 `persist-bundle`、面板或自动轮询直接
   插入用户 Profile；
2. 不复制其 `.credentials.yaml` 快照逻辑，也不复制自动 `danger-full-access` fallback；
3. 当前已有 Profile/Workspace snapshot、known-good、rescue、SHA-256、冲突拒绝、
   rollback receipt 和 observer-only Guardian，不再重复实现普通 snapshot/restore；
4. 如果产品确实需要“只撤销某一次插件安装”，后续在现有 Recovery 层增加受限的
   `safe-savepoint` 事务元数据和 surgical rollback：必须是 Profile allowlist、同一 Profile
   的 before/after 配对、默认 `CONFLICT`/`MANUAL_REVIEW`、显式 `-Force`、rescue 和
   receipt，并保持不触碰 sessions、credentials、Workspace 和 `node_modules`；
5. 该能力必须先有多插件时间线、冲突、路径重解析点和恢复不变量回归，再谈真实 DSH
   集成；在此之前不能把“设计已吸收”写成“生产恢复已支持”。

### `dsh-hotswap` 直接审计结论（2026-08-16）

用户追加的 `dsh-hotswap` 对应至少两个公开仓库。本轮只读核对了它们的 GitHub API
元数据、README 和文件树，没有安装到 Profile、没有复制源码，也没有读取或输出被删除
的历史 token。

| 仓库 | 直接核对到的信号 | 本项目的吸收/拒绝决定 |
| --- | --- | --- |
| [HongzhongL/dsh-hotswap](https://github.com/HongzhongL/dsh-hotswap) | `0.1.1`、MIT、`86b17d39f36979aeb80e745349ebeeeca5ff6e0a`；JavaScript 入口完整；同源 HTTP 状态/启停/重启/重置路由；Cordis `entry.update`、`_dispose`/`refresh`、ESM cache eviction；无 Actions、无测试目录 | 吸收“核心条目保护、ancestor/runtime-only/`!!js` 检查、串行队列、fail-closed、切换后分层 verdict”的设计形状；拒绝直接调用内部生命周期 API、自动 watcher、无额外鉴权的远程暴露和默认 Profile patch 写入 |
| [jarvan642/dsh-hotswap](https://github.com/jarvan642/dsh-hotswap) | `a05afc945af5f7666d48c207cfaf3fffa4bcfd58`；1 star；未发现许可证或 Actions；最近提交删除含 token 的 `.npmrc`；TypeScript/测试源码存在但没有 `lib/`，package 入口却指向 `lib/index.js`，无 `prepare`/`prepack`；`execSync` 拼接 npm 安装/卸载 | 不吸收；构建发布不闭合、许可证/历史凭据需要供应链复核，shell 拼接存在命令注入面，且 npm/Profile 路径与本包的 pnpm/DSH 约定不一致 |

这两个项目都把“插件启停不必重启 Host”做成了产品卖点，但它们不能证明当前 DSH
rc.6 的公开稳定生命周期合同，也没有提供本项目所需的真实 Profile、真实 Web、真实
任务恢复证据。因此 `dsh-plugin-debug` 继续保持默认 `observer-only / diagnostics-first`：
现有插件清单、`pluginEnablement` 能力矩阵和 Guardian 状态都是只读观察，不新增热切换
动作、POST 动作、`package.json` 自动安装/卸载或 `cordis.patch.yml` 自动改写；
`plugin_hotswap_check` 只做 capability probe，不调用任何生命周期方法。

另外，当前包锁定的 DSH rc.6 runtime 已包含官方
`@deepseek-ai/cordis-plugin-hmr@1.0.16`。它的 `ctx.hmr`/`getLinked()`/
`registerConfig()` 只能说明 runtime 有 HMR 组件；该组件要求 loader internals，
且 partial reload 仍依赖内部缓存、registry 和 fiber 生命周期。Debug 只把它作为
“观察到的 HMR 线索”，不把它当成可授权的公开生命周期合同。

后续若用户明确要做独立 opt-in hotswap 模块，现有 probe 仍必须在官方 API 可证明前
输出 `UNAVAILABLE`；真正实现前还必须通过核心保护/依赖图、disposable
fixture、真实 Profile dry-run、恶意同源请求、patch 冲突/回滚和 post-image 验证。热切换
成功、模块重新加载、页面需要刷新以及真实任务继续可用必须分别报告，不能把单一 HTTP
成功码当成生产可用。

## 许可证和归属

第三方项目的名称和链接仅用于研究引用；本项目没有复制它们的源码。发布前
仍应逐个确认第三方仓库的许可证和版本信息，不能仅凭 README 推断许可证。

本轮 GitHub 公开元数据中看到的 SPDX 线索如下；它们只是 API 元数据，不是
法律意见，也不改变本项目的 MIT 许可证：

| 项目 | 公开 SPDX 线索 |
| --- | --- |
| `zoahdev/dsh-plugin-doctor` | MIT |
| `chenw2759-wq/dsh-plugin-healthcheck` | MIT |
| `gordonlu/dsh-context-lens` | MIT |
| `wellorbetter/dsh-plugin-window-stats` | MIT |
| `PangYiMing/dsh-bisect-debug` | MIT |
| `linyp/dsh-plugin-langfuse` | MIT |
| `LX2000WASD/dsh-web-plugin-manager` | MIT |
| `awesome-dsh-plugin/awesome-dsh-plugin` | CC0-1.0 |

许可证信息只用于决定是否需要进一步人工复核；本项目没有把这些仓库作为
依赖，也没有复制其源码、测试 fixture 或发布脚本。

## 其他生态的设计参考（2026-08-16）

本轮还只读核对了几类非 DSH 项目，用来判断 Debug 插件下一步可以吸收什么，
而不是把它们的运行时引入本包。许可证判断以仓库或发布文件为准，README
徽章本身不作为法律依据。

| 项目 | 公开许可证线索 | 可吸收的设计 | 本包的边界决定 |
| --- | --- | --- | --- |
| [langchain-ai/langgraph](https://github.com/langchain-ai/langgraph) | MIT | checkpoint round-trip、namespace 隔离、metadata 保留、恢复/分支/prune 的契约测试 | 只吸收 recovery conformance 的测试模型；不引入数据库或 LangGraph runtime |
| [OpenHands/OpenHands](https://github.com/OpenHands/OpenHands) | MIT | 将 `failed`、`connectivity-only`、`verified`、`unavailable` 分层；区分连接失败和凭据失败 | 插件健康检查保持默认只读，安装、启停和授权必须是显式动作 |
| [modelcontextprotocol/inspector](https://github.com/modelcontextprotocol/inspector) | package metadata 声明 MIT；仓库 API 的 license 字段需单独复核 | Web/CLI/TUI 共用一套 inspector 和 session 检查面 | 不把“能连接”当成“能安全执行”；继续保持 loopback、allowlist、动作白名单和脱敏 |
| [open-telemetry/opentelemetry-collector](https://github.com/open-telemetry/opentelemetry-collector) 与 [healthcheck extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/healthcheckextension) | Apache-2.0 | liveness/readiness/functional verification 分离、机器可读 component status、生命周期顺序 | 只吸收状态协议；保留 `UNAVAILABLE/PARTIAL/WARN/FAIL`，不把探针当作恢复证明 |
| [temporalio/temporal](https://github.com/temporalio/temporal) | MIT | retry/replay、durable execution 的状态机和结构化 health check 类型 | 仅用于设计 known-good/recovery 的状态语义，不引入 Temporal 服务 |
| [backstage/backstage](https://github.com/backstage/backstage) | Apache-2.0 | 稳定 plugin ID、显式 service/dependency contract、生命周期和健康状态分层 | 不引入微服务；把能力矩阵、manifest、依赖图和 preflight 保持在本地包内 |
| [getsentry/sentry](https://github.com/getsentry/sentry) / [langfuse/langfuse](https://github.com/langfuse/langfuse) | 当前仓库元数据并不足以直接作完整依赖许可结论 | incident、trace、breadcrumb、evaluation 的关联键和 replay fixture 组织方式 | 只吸收数据模型；不保存 raw prompt、Tool 参数/结果、凭据或完整路径，也不接入外部 telemetry |

因此下一阶段的候选顺序是：先补 LangGraph 风格的 recovery round-trip/冲突
契约，再将 OpenHands 风格的 plugin health verdict 统一到 CLI、JSON 和页面，
最后评估 OpenTelemetry 风格的 readiness 状态。真实 durable rewind、远端
ledger、网络 telemetry、自动安装/启停和无 allowlist support bundle 仍不属于
当前发布候选；每一项都需要新的 Host 合同、隐私审查和独立回归测试。
