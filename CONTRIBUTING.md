# 贡献与维护

这个仓库只维护一个公开运行时包：`packages/dsh-plugin-debug`。它是
“离线优先、元数据优先、失败即停止”的调试工具，不是插件商店，也不把
`dsh-plugin-store` 作为依赖。

维护优先级和明确的非目标见 [`ROADMAP.md`](ROADMAP.md)。如果路线图与
真实 DSH/Host 证据冲突，以可复现测试和发布门禁为准，不以文档愿望代替运行证明。

## 提交功能前

1. 先说明功能影响的边界：读取什么、写入什么、是否会停止已确认的 DSH
   子进程、是否需要真实 DSH/浏览器；不要把合成 fixture 说成线上证明。
2. 修改 `src/`、`tools/`、入口脚本和测试源码；`lib/` 与
   `bundle-manifest.json` 由构建脚本生成。
3. 为正常路径和失败路径各加一个脱敏回归。任何会访问网络、安装任意包、
   调用私有 DSH 生命周期 API（例如 `_dispose`/`refresh`）或自动监听
   `package.json` 的功能，都必须先有单独的安全设计和明确的 opt-in 边界。

## 本地门禁

在包目录运行：

```powershell
npm ci --ignore-scripts
npm ci --prefix .\tools\runtime --omit=dev --ignore-scripts --no-audit --no-fund
npm audit --prefix .\tools\runtime --registry=https://registry.npmjs.org --omit=dev --audit-level=high
npm run check
pwsh -NoLogo -NoProfile -File .\Test-DSHStandalone.ps1
```

`npm run check` 会重新生成 `lib/` 和 bundle manifest，验证源文件与生成物
的 SHA-256，并对 `src/`、`lib/`、`scripts/`、`tests/` 的 JavaScript 做
语法检查。发布边界验证必须在安装依赖前的干净 staging 或 fresh clone
中运行：

```powershell
Push-Location C:\path\to\dsh-open-source
.\scripts\Verify-Publication.ps1
Pop-Location
```

安全依赖审计使用官方 npm advisory API：
`npm audit --registry=https://registry.npmjs.org --omit=dev --audit-level=high`。
上面的本地流程和 CI 还会用同一官方 endpoint 单独审计包内 pinned DSH runtime；
runtime lockfile 是发布包的一部分，不能只审计包根目录。
仓库 lockfile 中保留的国内镜像 URL 不支持 npm audit endpoint；直接对
`registry.npmmirror.com` 执行 audit 会返回 404，不能把这个网络端点错误
记录成“依赖安全通过”。

如果需要验证实际包，不要把 `node_modules` 复制进 staging；使用
`npm pack` 解包到空目录，再检查入口和 Standalone。真实 DSH Web、Host、
模型请求、第三方插件热安装/卸载仍需单独的兼容性证据。

## 发布流程

先创建 candidate source commit，推送后回读远端 SHA；从这个精确 SHA 做
fresh clone，跑同一套门禁；只有通过后才提交 release evidence，更新
`RELEASE-MANIFEST.json` 的 `publishedCommit` 与 UTC 时间。不要把本地
工作树、旧 tag 或历史 release body 当成新版本证据。`Publish-GitHub.ps1`
必须从真实仓库 clone 运行，它的 `-DryRun` 只检查路径，不会登录、提交或推送。

## Pull Request 检查表

- [ ] 没有凭据、`.dsh`、日志、state、coverage、`node_modules` 或真实用户数据。
- [ ] `npm run check`、Standalone 和相关 PowerShell 回归均有真实退出码。
- [ ] README、CHANGELOG、版本号、lockfile、bundle manifest 一致。
- [ ] 生产兼容性、离线 fixture 和未验证范围分别写清楚。
