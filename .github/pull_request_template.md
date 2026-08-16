## 变更说明

请用几句话说明修改了什么、为什么修改，以及哪些行为保持不变。

## 验证清单

- [ ] 已运行与改动相关的 Node/PowerShell 测试，并记录真实退出码。
- [ ] 功能行为变化已同时增加正常路径和失败路径回归。
- [ ] 若改了 `src/`、脚本或版本，已按流程重新生成 `lib/` 和 `bundle-manifest.json`。
- [ ] 已运行 `scripts/Verify-Publication.ps1`，确认没有 `node_modules`、state、logs、凭据或插件商店残留。
- [ ] 没有提交 API Token、Cookie、Authorization、会话正文、Tool 参数/结果或完整本地路径。
- [ ] 已区分 `PASS`、`PARTIAL`、`UNAVAILABLE`、`WARN` 和 `FAIL`，没有把静态 fixture 写成真实 DSH 验证。

## 额外说明

如果需要真实 DSH、浏览器、Host API 或外部服务才能验证，请明确写出当前未验证的部分。
