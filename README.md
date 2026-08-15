# DSH Debug Plugin

This repository is the local public-release candidate for one combined DSH
Debug Plugin. The product directory is `packages/dsh-plugin-debug`; its npm/DSH
runtime ID is `dsh-plugin-debug`; existing Profiles that reference the older provenance ID require an explicit migration or reinstall.
The single package contains provenance, diagnostics, recovery, Crash Guard,
resource-pressure, Incident, Trace/Eval, constrained self-repair, Workbench,
one-click launcher tools, tests and deterministic test fixtures.

本仓库现在只公开一个自制 DSH Debug 插件，目录是
`packages/dsh-plugin-debug`，npm/DSH 包名为 `dsh-plugin-debug`；
已有旧 provenance Profile 需要显式迁移或重新安装。所有检测、debug、恢复、Crash Guard、Workbench 和一键
启动源码都已合并到这个单包中。插件商店源码与能力已移除。

中文使用、测试、升级和开源边界说明见
[`packages/dsh-plugin-debug/README.zh-CN.md`](packages/dsh-plugin-debug/README.zh-CN.md)。

## Single-package layout

```text
packages/dsh-plugin-debug/
  src/                       Web Client provenance implementation
  lib/                       built DSH runtime bundle
  DSH-Debug.ps1              public debug dispatcher
  Start-DSH-Debug.*          default debug entry points
  Start-DSH-Combined.*       optional Kimi/Codex overlay entry points
  tools/                     all Host-side debug, recovery and launcher tools
    Start-DSH.*              start/stop and Crash Guard launcher
    DSH-Workbench.ps1        diagnostics, snapshots, repair and session actions
    DSH-Recovery.*           Profile/workspace recovery
    DSH-ResourcePressure.*   bounded resource-pressure evidence
    DSH-Incident.*           cross-layer incident evidence
    runtime/                 pinned runtime manifests, no node_modules
  tests/                     Node runtime tests
```

There is no second public host-tool component in this candidate. The original
source directories were removed from the projects tree after migration review
and are recoverable only from the Windows Recycle Bin; the public source of
truth is this single package.

The source-by-source merge decisions, including intentional legacy bridge and
plugin-store exclusions, are recorded in `MIGRATION-MANIFEST.md`.
The bounded ecosystem comparison and rejected capability decisions are in
`RESEARCH-ECOSYSTEM.md`.

## Component boundary

| Component | Public role | Independently installable? |
| --- | --- | --- |
| `packages/dsh-plugin-debug` | one combined DSH Debug Plugin; runtime ID `dsh-plugin-debug` | Yes; the only public package |
| `packages/dsh-plugin-debug/tools/fixtures` | deterministic, sanitized trace/browser inputs used by tests and examples | No; data only |

The plugin-store source and capability were removed. They are not listed as a
component and are not required by any debug entry point. Crash Guard's failing
runtime is generated inside a temporary directory by the test harness; no
standalone crash-fixture package is shipped.

## Local verification

From `packages/dsh-plugin-debug`:

```powershell
npm test
npm run check
.\Test-DSHStandalone.ps1
.\tools\Test-DSHResourcePressure.ps1
.\tools\Test-DSHIncidentRuntimeEvidence.ps1
```

The tests use bounded temporary fixtures. They are not proof of a real
production DSH, GitHub account, device or external service.

## Publication boundary

The candidate must not contain `.dsh`, `.codex`, Profile state, logs, state,
coverage, `node_modules`, credentials, private keys or temporary artifacts.
The first public release is available at
`https://github.com/shine-233/dsh-plugin-debug` on `main`. A fresh-clone
verification is still a separate release gate; see `PUBLICATION-CHECKLIST.md`
and `PUBLISHING.md` before publishing later changes.
