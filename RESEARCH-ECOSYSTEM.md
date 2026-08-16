# DSH Debug Ecosystem Research

研究日期：2026-08-16（中国标准时间）

这份记录说明本项目为什么吸收某些能力、拒绝某些能力，以及检索结果
的边界。它不是“扫描 GitHub 全部插件”的声明，也不是第三方代码的复制
清单。本轮使用 GitHub 的公开只读 API 和公开仓库页面核对名称、README、
文件树、许可证线索和实现形状；没有上传本机源码、Session、Cookie、日志、
Tool 参数或诊断文件。

## 检索边界

本轮的实际目标是寻找和 DSH Debug Plugin 直接相关的 doctor、health、trace、
recovery、plugin manager、bisect 和 observability 方案。查询结果经过人工
筛选，不把搜索结果数量当成生态完整性证明。没有把没有明确许可证的代码复制
进本项目，也没有把任何第三方仓库加入运行时依赖。

本轮只对下面已经选定的仓库读取 GitHub 公共 API 元数据，并查看公开 README
和文件树；没有做全站关键词扫描、克隆仓库或下载源码：

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

| 项目 | SPDX 元数据 | 观察到的能力 | 本项目的吸收或拒绝决定 |
| --- | --- | --- | --- |
| [zoahdev/dsh-plugin-doctor](https://github.com/zoahdev/dsh-plugin-doctor) | MIT | manifest/patch/entry/files 检查、fresh-profile 安装、BOM、大文件、入口副作用、环境检查、JSON CI 报告 | 吸收分层 doctor、fresh-profile 验证和可机器读取报告；本项目仍以离线、只读、边界明确为默认 |
| [chenw2759-wq/dsh-plugin-healthcheck](https://github.com/chenw2759-wq/dsh-plugin-healthcheck) | MIT | L0 静态检查、L1 composition、L2 isolated boot、恶意代码扫描、safe repair/rollback | 吸收分层健康门和安全修复方向；不自动改 Profile，不自动处理核心包，无法归因时 fail-closed |
| [gordonlu/dsh-context-lens](https://github.com/gordonlu/dsh-context-lens) | MIT | metadata-only context profiling、tool schema fingerprint、cache delta、replay consistency | 吸收 metadata-only trace/profile 和 change-first 诊断；拒绝持久化原始请求、Tool 参数和结果正文 |
| [wellorbetter/dsh-plugin-window-stats](https://github.com/wellorbetter/dsh-plugin-window-stats) | MIT | session overview、token/context pressure、成本估算、本地只读分析 | 吸收资源压力和窗口统计的只读形状；当前不宣称可从没有 Session ID 的真实实例读取 Tool Call |
| [PangYiMing/dsh-bisect-debug](https://github.com/PangYiMing/dsh-bisect-debug) | MIT | 代码、边界和 Git commit 二分定位 | 已吸收为 `plugin-bisect-plan` 的只读插件候选排序、证据摘要和人工步骤；不自动切换 Git 工作树、不执行命令、不修改 Profile |
| [linyp/dsh-plugin-langfuse](https://github.com/linyp/dsh-plugin-langfuse) | MIT | OpenTelemetry/Langfuse 外部导出 | 拒绝：会扩大网络出口，并可能泄漏原始内容；当前包只做本地 metadata-only evidence |
| [LX2000WASD/dsh-web-plugin-manager](https://github.com/LX2000WASD/dsh-web-plugin-manager) | MIT | 运行时启停、依赖/冲突/健康检查 | 吸收只读 inventory 和明确第三方隔离；拒绝把本项目变成 marketplace 或任意运行时管理器 |
| [awesome-dsh-plugin/awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin) | CC0-1.0 | 生态索引和插件发现 | 仅作为发布前人工审查入口，不作为运行时依赖 |
| [jorinyang/dsh-doctor](https://github.com/jorinyang/dsh-doctor) | MIT（包内账本已核对） | 环境/端口/Profile/HTTP/disk 检查，safe/deps/full 修复 scope，LIFO journal，Web 不可用时的 CLI | 吸收只读 doctor、独立 Host 入口和 receipt 思路；拒绝 full process cleanup、shell 拼接和宽泛 repair |
| [lire1131/dsh-undo-plugin](https://github.com/lire1131/dsh-undo-plugin) | 本轮未重新核对 | 配置快照、undo/redo、离线 CLI/GUI、启动异常横幅 | 已有 snapshot/restore、Crash Guard 和页面通知；不复制其 GUI 或包加载方式 |
| [PerryLink/dsh-checkpoint-rewind](https://github.com/PerryLink/dsh-checkpoint-rewind) | 本轮未重新核对 | 变更前 checkpoint、三阶段事务、配额、恢复日志、Session fork | 吸收 checkpoint/receipt 的安全形状；真实 durable rewind 事件未在 DSH rc.6 验证，因此不伪造该能力 |
| [BiBoyang/dsh-eval-harness](https://github.com/BiBoyang/dsh-eval-harness) | 本轮未重新核对 | 隔离 workspace/session、JSONL trace、baseline PASS/WARN/FAIL 门禁 | 已有脱敏 Trace/Eval/baseline；zstd 解码和真实 headless LLM 回归仍标为未完成 |
| [akira399/dsh-guardian](https://github.com/akira399/dsh-guardian) | MIT；本轮只读复核的 `main` 提交为 `5bf7ef3ad56d5e0b78e40071ac99d94b697e468b` | 插件预检、重复 Tool Call 循环、Agent/Workflow 递归、中断感知、`safeToRestart` 和实际安全重启助手 | 单包已独立实现预检、运行时循环/递归观察、冷却提示、事件上报和只读状态检查；不复制源码，不并入实际重启脚本 |

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
| [zoahdev/dsh-plugin-doctor](https://github.com/zoahdev/dsh-plugin-doctor) | README 说明 manifest/patch/entry、pack/install/config、fresh-profile、BOM、大文件和入口检查，并提供 JSON CI 输出；API 返回 MIT | 当前单包已有离线 repository check、plugin preflight、dependency graph、fake offline install、publication verifier 和 standalone 测试；不把 DSH 官方尚未提供的 `dsh plugin check` 入口冒充成已存在 |
| [jorinyang/dsh-doctor](https://github.com/jorinyang/dsh-doctor) | README 将诊断、分级修复、LIFO undo 和运行时服务分开，并保留 Web 不可用时的 CLI 方向；API 返回 MIT | 保留只读 doctor、receipt、known-good 和显式恢复边界；恢复快照现在明确排除 `.env`/敏感内容，回滚不会覆盖它们 |
| [PangYiMing/dsh-bisect-debug](https://github.com/PangYiMing/dsh-bisect-debug) | README 提供代码、边界和 Git commit 三种二分，并要求干净工作树、退出码和显式 reset | 已吸收为只读 `plugin-bisect-plan`；不自动切换工作树、reset、删除文件或执行用户命令 |
| [Areium/dsh-fail-logger](https://github.com/Areium/dsh-fail-logger) | README 说明只记录 `isError=true` 的 Tool failure，做去重、计数、确定性排序、TTL 清理和脱敏；API 返回 MIT | 吸收“失败证据应可控留存”的设计形状，但不把原始失败正文写入 skill；Guardian 事件只保存指纹/类别，并以有界文件轮转替代无限追加 |
| [VS Code Extension Bisect](https://code.visualstudio.com/docs/editor/extension-marketplace) | 官方文档把 Extension Bisect 定义为通过启停扩展缩小问题范围 | DSH 的 `plugin-bisect-plan` 保留同样的缩小搜索空间思路，但使用安全候选、保护核心包和人工步骤；不在用户工作树上自动做破坏性切换 |

本轮没有把“看过这些项目”写成“已经完成生产兼容”。真正新增到代码的是 Guardian
事件日志的有界轮转/过期归档清理，以及恢复快照的敏感文件排除；两者都配有回归
断言。网络导出、常驻 watcher、自动 Git bisect、durable rewind 和模型自行执行
修复仍保持明确的未吸收状态。

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
