# DSH Debug Plugin quick start

`dsh-plugin-debug` is the single runtime plugin for the local DSH diagnostic
stack. It combines pointer provenance, client diagnostics, plugin health,
incident capture, trace/autopsy, Crash Guard, known-good snapshots, bounded
recovery, and constrained repair planning. This package has no plugin-store
capability or integration.

## Install the one plugin

From the package root, use the pinned local DSH runtime:

```powershell
node .\tools\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js `
  plugin --profile debug add . --offline
```

After installation, restart DSH and open its Web UI. The debug settings panel
is available from the normal settings surface. It is safe to leave the panel
disabled; the client does not change tool policy unless an explicit policy
configuration enables it.

## Foolproof Windows entry point

Double-click `Start-DSH-Debug.vbs`, or run:

```powershell
.\Start-DSH-Debug.ps1 -Profile debug -Port 3081
```

The entry point starts the pinned runtime, installs this local bundle offline
when needed, enables the bounded Crash Guard/supervisor, waits for loopback Web
readiness, and then opens the browser unless `-NoBrowser` is supplied.

## Read-only diagnosis

The dispatcher keeps the complete diagnostic action surface from the original
provenance project:

```powershell
.\Debug-DSH.ps1 -Action doctor -Profile debug -SkipApi
.\Debug-DSH.ps1 -Action plugin-health -Profile debug -SkipApi
.\Debug-DSH.ps1 -Action incident-capture -Profile debug -SkipApi
.\Debug-DSH.ps1 -Action trace-autopsy -InputPath .\tools\fixtures\tool-call-trace.json
```

Repair and recovery actions remain bounded and explicit. A diagnostic report is
evidence, not proof that a production DSH process was repaired.
