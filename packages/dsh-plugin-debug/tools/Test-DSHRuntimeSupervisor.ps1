[CmdletBinding()]
param(
  [int]$TimeoutSec = 30,
  [int]$Port = 0,
  [switch]$UnresolvedPluginFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-provenance-runtime-supervisor-' + [Guid]::NewGuid().ToString('N'))
$fixtureTools = Join-Path $tempRoot 'tools'
$fixtureRuntime = Join-Path $fixtureTools 'runtime'
$fixtureBin = Join-Path $fixtureRuntime 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$fixtureDshHome = Join-Path $tempRoot 'dsh-home'
$fixtureProfile = Join-Path $fixtureDshHome 'profiles\fixture'
$fixtureWorkspace = Join-Path $tempRoot 'workspace'
$fixtureState = Join-Path $tempRoot 'state'
$bootFile = Join-Path $tempRoot 'boot-count.txt'
$launcher = Join-Path $fixtureTools 'Start-DSH.ps1'
$guardModule = Join-Path $fixtureTools 'DSH-Guard.psm1'
$manifestPath = Join-Path $fixtureProfile 'package.json'
$guardStatePath = Join-Path $fixtureState 'guard-state.json'
$guardPatchPath = Join-Path $fixtureState 'guard.patch.yml'
$startupIncidentPath = Join-Path $fixtureState 'startup-incident.json'
$launcherLogPath = Join-Path $fixtureState 'logs\launcher.log'
$pidRecordPath = Join-Path $fixtureState 'dsh-web.pid.json'
$previousDshHome = $env:DSH_HOME
$launcherProcess = $null
$fixtureProcess = $null

function Write-FixtureText {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Read-BootCount {
  if (-not (Test-Path -LiteralPath $bootFile -PathType Leaf)) { return 0 }
  try { return [int](Get-Content -LiteralPath $bootFile -Raw -Encoding UTF8) } catch { return 0 }
}

function Read-FixtureText {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $stream = $null
    $reader = $null
    try {
      # The launcher appends while the supervisor polls.  Open a shared read
      # stream so the fixture observes the log without racing the writer.
      $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true)
      return $reader.ReadToEnd()
    } catch {
      if ($attempt -eq 19) { return '' }
      Start-Sleep -Milliseconds 100
    } finally {
      if ($null -ne $reader) { $reader.Dispose() }
      elseif ($null -ne $stream) { $stream.Dispose() }
    }
  }
  return ''
}

function Get-FreeLoopbackPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    $listener.Stop()
  }
}

function Stop-FixtureProcesses {
  if ($null -ne $fixtureProcess) {
    try {
      $fixtureProcess.Refresh()
      if (-not $fixtureProcess.HasExited) { Stop-Process -Id $fixtureProcess.Id -Force -ErrorAction SilentlyContinue }
    } catch { }
  }
  if ($null -ne $launcherProcess) {
    try {
      $launcherProcess.Refresh()
      if (-not $launcherProcess.HasExited) { Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue }
    } catch { }
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while ([DateTime]::UtcNow -lt $deadline) {
    $active = @($fixtureProcess, $launcherProcess | Where-Object { $null -ne $_ -and -not $_.HasExited })
    if ($active.Count -eq 0) { break }
    Start-Sleep -Milliseconds 100
  }
}

try {
  if ($TimeoutSec -lt 10 -or $TimeoutSec -gt 180) { throw 'TimeoutSec must be between 10 and 180' }
  if ($Port -lt 0 -or $Port -gt 65535) { throw 'Port must be 0 (auto) or between 1 and 65535' }
  $fixturePort = if ($Port -eq 0) { Get-FreeLoopbackPort } else { $Port }
  New-Item -ItemType Directory -Path $fixtureTools,$fixtureRuntime,$fixtureProfile,$fixtureWorkspace,$fixtureState -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $packageRoot 'Start-DSH.ps1') -Destination $launcher -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'DSH-State.psm1') -Destination (Join-Path $fixtureTools 'DSH-State.psm1') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'DSH-Guard.psm1') -Destination $guardModule -Force
  Write-FixtureText -Path (Join-Path $fixtureRuntime 'package.json') -Text '{"name":"dsh-provenance-runtime-supervisor-fixture","private":true}'
  Write-FixtureText -Path $manifestPath -Text (@{
    name = 'dsh-provenance-runtime-supervisor-profile'
    version = '0.0.0'
    dependencies = [ordered]@{ 'test-dsh-plugin' = 'file:..\..\test-dsh-plugin' }
  } | ConvertTo-Json -Depth 8)
  Write-FixtureText -Path (Join-Path $fixtureWorkspace 'README.md') -Text "isolated runtime supervisor fixture`n"

  Write-FixtureText -Path $fixtureBin -Text @'
const fs = require('node:fs');
const http = require('node:http');
const args = process.argv.slice(2);
const argument = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
};
const bootFile = process.env.DSH_RUNTIME_SUPERVISOR_BOOT_FILE;
const priorBoots = fs.existsSync(bootFile) ? Number(fs.readFileSync(bootFile, 'utf8')) || 0 : 0;
fs.writeFileSync(bootFile, String(priorBoots + 1), 'utf8');
const unresolvedPlugin = process.env.DSH_RUNTIME_SUPERVISOR_UNRESOLVED === '1';
const failingModule = unresolvedPlugin ? 'unmapped-plugin' : 'test-dsh-plugin';
const patchPath = argument('--patch');
const patch = patchPath && fs.existsSync(patchPath) ? fs.readFileSync(patchPath, 'utf8') : '';
if (priorBoots > 0 && !unresolvedPlugin && (!/id:\s*'test-dsh-plugin'/.test(patch) || !/disabled:\s*true/.test(patch))) {
  process.stderr.write('Error: runtime supervisor fixture refused to start without quarantine patch\n');
  process.exit(48);
}
let failed = false;
let inventoryRequests = 0;
const port = Number(argument('--port'));
const server = http.createServer((request, response) => {
  if (request.url === '/api/pluginInventory/list') {
    inventoryRequests += 1;
    response.setHeader('content-type', 'application/json');
    const entries = failed ? [{ entryId: failingModule, moduleName: failingModule, enabled: true, fiberPhase: 'failed' }] : [];
    response.end(JSON.stringify({ result: { ok: true, value: { entries } } }));
    // The first inventory request is the launcher's ready check. Fail only
    // after that response so the test deterministically exercises the
    // keep-alive supervisor's runtime restart path instead of sometimes
    // racing startup Crash Guard on a busy Windows runner.
    if (priorBoots === 0 && inventoryRequests === 1) {
      failed = true;
      process.stderr.write('Error: test-dsh-plugin runtime failed after Web ready\n');
    }
    return;
  }
  response.setHeader('content-type', 'text/html; charset=utf-8');
  response.end('<!doctype html><title>DeepSeek Harness runtime supervisor fixture</title><main>DeepSeek Harness fixture ready</main>');
});
server.listen(port, '127.0.0.1');
const close = () => server.close(() => process.exit(0));
process.on('SIGTERM', close);
process.on('SIGINT', close);
'@

  $env:DSH_HOME = $fixtureDshHome
  $env:DSH_RUNTIME_SUPERVISOR_BOOT_FILE = $bootFile
  $env:DSH_RUNTIME_SUPERVISOR_UNRESOLVED = if ($UnresolvedPluginFailure) { '1' } else { '0' }
  $powerShellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -eq $powerShellCommand) { throw 'Windows PowerShell executable is required for the runtime supervisor fixture' }
  $argumentList = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-Port', [string]$fixturePort, '-HostName', '127.0.0.1', '-Profile', 'fixture',
    '-Workspace', $fixtureWorkspace, '-StateRoot', $fixtureState,
    '-EnableCrashGuard', '-GuardThreshold', '1', '-NoBrowser', '-NoErrorDialog', '-NoInstall',
    '-NoPluginInstall', '-KeepAlive', '-SupervisorIntervalSec', '1', '-StartupTimeoutSec', '10'
  )
  $launcherProcess = Start-Process -FilePath $powerShellCommand.Source -ArgumentList $argumentList -WorkingDirectory $fixtureWorkspace -WindowStyle Hidden -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  $recovered = $false
  $blockedAsDegraded = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $pidRecordPath -PathType Leaf) {
      try { $record = Get-Content -LiteralPath $pidRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json; $fixtureProcess = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue } catch { }
    }
    $guardState = $null
    if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) { try { $guardState = Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $supervisorState = $null
    if (Test-Path -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -PathType Leaf) {
      try { $supervisorState = Get-Content -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $quarantine = @(
      if ($null -eq $guardState) { @() }
      else { @($guardState.quarantined | Where-Object { [string]$_.moduleName -eq 'test-dsh-plugin' }) }
    )
    $log = Read-FixtureText -Path $launcherLogPath
    if ($UnresolvedPluginFailure -and
        $null -ne $supervisorState -and [string]$supervisorState.status -eq 'degraded' -and
        (Read-BootCount) -eq 1) {
      $blockedAsDegraded = $true
      break
    }
    if (-not $UnresolvedPluginFailure -and (Read-BootCount) -ge 2 -and $quarantine.Count -eq 1 -and
        @($log -split "`r?`n" | Where-Object { $_ -match 'DSH Web ready' }).Count -ge 2 -and
        $null -ne $supervisorState -and [string]$supervisorState.status -eq 'healthy') {
      $recovered = $true
      break
    }
    Start-Sleep -Milliseconds 250
  }
  if ($UnresolvedPluginFailure) {
    if (-not $blockedAsDegraded) {
      throw "unresolved plugin failure was not blocked as degraded within ${TimeoutSec}s; boots=$(Read-BootCount); log=$log"
    }
    $launcherProcess.Refresh()
    $launcherExitDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $launcherProcess.HasExited -and [DateTime]::UtcNow -lt $launcherExitDeadline) {
      Start-Sleep -Milliseconds 100
      $launcherProcess.Refresh()
    }
    if (-not $launcherProcess.HasExited) {
      throw 'launcher remained alive after an unresolved plugin failure was marked degraded'
    }
    $launcherExitCode = [int]$launcherProcess.ExitCode
    if ($launcherExitCode -eq 0) {
      throw 'launcher returned success after an unresolved plugin failure'
    }
    $finalGuardState = $null
    if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) {
      try { $finalGuardState = Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $finalSupervisorState = $null
    if (Test-Path -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -PathType Leaf) {
      try { $finalSupervisorState = Get-Content -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $finalStartupIncident = $null
    if (Test-Path -LiteralPath $startupIncidentPath -PathType Leaf) {
      try { $finalStartupIncident = Get-Content -LiteralPath $startupIncidentPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $finalQuarantineCount = if ($null -eq $finalGuardState) { 0 } else { @($finalGuardState.quarantined).Count }
    if ($finalQuarantineCount -ne 0) {
      throw "unresolved plugin failure unexpectedly quarantined $finalQuarantineCount plugin(s)"
    }
    [ordered]@{
      result = 'PASS'
      scenario = 'unresolved-plugin-fail-closed'
      bootCount = Read-BootCount
      launcherExitCode = $launcherExitCode
      quarantineCount = $finalQuarantineCount
      startupBlocked = $true
      startupIncidentStatus = if ($null -eq $finalStartupIncident) { $null } else { [string]$finalStartupIncident.status }
      supervisorStatus = if ($null -eq $finalSupervisorState) { $null } else { [string]$finalSupervisorState.status }
      supervisorReason = if ($null -eq $finalSupervisorState) { $null } else { [string]$finalSupervisorState.reason }
    } | ConvertTo-Json -Depth 12
    exit 0
  }
  if (-not $recovered) {
    $log = Read-FixtureText -Path $launcherLogPath
    $supervisorStateText = if (Test-Path -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -PathType Leaf) {
      Get-Content -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -Raw -Encoding UTF8
    } else { '' }
    $guardStateText = if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) {
      Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8
    } else { '' }
    $stderrText = if (Test-Path -LiteralPath (Join-Path $fixtureState 'logs\dsh.stderr.log') -PathType Leaf) {
      Get-Content -LiteralPath (Join-Path $fixtureState 'logs\dsh.stderr.log') -Raw -Encoding UTF8
    } else { '' }
    throw "runtime supervisor did not recover within ${TimeoutSec}s; boots=$(Read-BootCount); supervisor=$supervisorStateText; guard=$guardStateText; stderr=$stderrText; log=$log"
  }
  if ($log -notmatch '等待旧 DSH 子进程释放端口') {
    throw 'runtime supervisor recovery did not exercise the guarded port-release wait'
  }
  $finalSupervisorState = $null
  if (Test-Path -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -PathType Leaf) {
    try { $finalSupervisorState = Get-Content -LiteralPath (Join-Path $fixtureState 'supervisor-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  [ordered]@{
    result = 'PASS'
    port = $fixturePort
    portReleaseWaitObserved = $true
    bootCount = Read-BootCount
    quarantinedPlugin = 'test-dsh-plugin'
    reversiblePatchPresent = (Test-Path -LiteralPath $guardPatchPath -PathType Leaf) -and ((Get-Content -LiteralPath $guardPatchPath -Raw -Encoding UTF8) -match 'disabled: true')
    runtimeFailureObserved = $true
    webReadyAfterRestart = $true
    supervisorStatus = if ($null -eq $finalSupervisorState) { $null } else { [string]$finalSupervisorState.status }
    supervisorReason = if ($null -eq $finalSupervisorState) { $null } else { [string]$finalSupervisorState.reason }
    supervisorRestartCount = if ($null -eq $finalSupervisorState) { $null } else { [int]$finalSupervisorState.restartCount }
  } | ConvertTo-Json -Depth 12
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    error = $_.Exception.Message
    position = $_.InvocationInfo.PositionMessage
    stack = $_.ScriptStackTrace
  } | ConvertTo-Json -Depth 8
  exit 1
} finally {
  Stop-FixtureProcesses
  if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
  Remove-Item Env:DSH_RUNTIME_SUPERVISOR_BOOT_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:DSH_RUNTIME_SUPERVISOR_UNRESOLVED -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $tempRoot) {
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
      try {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
        break
      } catch {
        if ([DateTime]::UtcNow -ge $cleanupDeadline) { break }
        Start-Sleep -Milliseconds 100
      }
    } while ([DateTime]::UtcNow -lt $cleanupDeadline)
  }
}
