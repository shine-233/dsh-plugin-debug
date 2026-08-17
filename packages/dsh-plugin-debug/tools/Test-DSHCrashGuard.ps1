[CmdletBinding()]
param(
  [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $packageRoot 'DSH-PowerShell.ps1')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-provenance-crash-guard-' + [Guid]::NewGuid().ToString('N'))
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

function Stop-FixtureProcess {
  if ($null -eq $script:fixtureProcess) { return }
  try {
    $script:fixtureProcess.Refresh()
    if (-not $script:fixtureProcess.HasExited) {
      Stop-Process -Id $script:fixtureProcess.Id -Force -ErrorAction SilentlyContinue
      [void]$script:fixtureProcess.WaitForExit(3000)
    }
  } catch { }
}

try {
  if ($TimeoutSec -lt 10 -or $TimeoutSec -gt 180) { throw 'TimeoutSec must be between 10 and 180' }
  New-Item -ItemType Directory -Path $fixtureTools,$fixtureRuntime,$fixtureProfile,$fixtureWorkspace,$fixtureState -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $packageRoot 'Start-DSH.ps1') -Destination $launcher -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'DSH-State.psm1') -Destination (Join-Path $fixtureTools 'DSH-State.psm1') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'DSH-Guard.psm1') -Destination $guardModule -Force

  Write-FixtureText -Path (Join-Path $fixtureRuntime 'package.json') -Text '{"name":"dsh-provenance-crash-fixture-runtime","private":true}'
  Write-FixtureText -Path $manifestPath -Text (@{
    name = 'dsh-provenance-crash-fixture-profile'
    version = '0.0.0'
    dependencies = [ordered]@{ 'test-dsh-plugin' = 'file:..\..\test-dsh-plugin' }
  } | ConvertTo-Json -Depth 8)
  Write-FixtureText -Path (Join-Path $fixtureWorkspace 'README.md') -Text "isolated crash guard fixture`n"
  Write-FixtureText -Path $fixtureBin -Text @'
const fs = require('node:fs');
const http = require('node:http');

const args = process.argv.slice(2);
const argument = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
};
const bootFile = process.env.DSH_CRASH_FIXTURE_BOOT_FILE;
const priorBoots = fs.existsSync(bootFile) ? Number(fs.readFileSync(bootFile, 'utf8')) || 0 : 0;
fs.writeFileSync(bootFile, String(priorBoots + 1), 'utf8');

if (priorBoots === 0) {
  process.stderr.write('Error: test-dsh-plugin failed to initialize\n');
  process.exit(47);
}

const patchPath = argument('--patch');
const patch = patchPath && fs.existsSync(patchPath) ? fs.readFileSync(patchPath, 'utf8') : '';
if (!/id:\s*'test-dsh-plugin'/.test(patch) || !/disabled:\s*true/.test(patch)) {
  process.stderr.write('Error: fixture refused to start without the quarantine patch\n');
  process.exit(48);
}

const port = Number(argument('--port'));
const server = http.createServer((request, response) => {
  if (request.url === '/api/pluginInventory/list') {
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ result: { ok: true, value: { entries: [] } } }));
    return;
  }
  response.setHeader('content-type', 'text/html; charset=utf-8');
  response.end('<!doctype html><title>DeepSeek Harness fixture</title><main>DeepSeek Harness fixture ready</main>');
});
server.listen(port, '127.0.0.1');
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
'@

  $env:DSH_HOME = $fixtureDshHome
  $env:DSH_CRASH_FIXTURE_BOOT_FILE = $bootFile
  $powerShellPath = Get-DshPowerShellPath
  $argumentList = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-Port', '32179', '-HostName', '127.0.0.1', '-Profile', 'fixture',
    '-Workspace', $fixtureWorkspace, '-StateRoot', $fixtureState,
    '-EnableCrashGuard', '-GuardThreshold', '1', '-NoBrowser', '-NoInstall', '-NoPluginInstall',
    '-StartupTimeoutSec', '15'
  )
  $script:launcherProcess = Start-Process -FilePath $powerShellPath -ArgumentList $argumentList -WorkingDirectory $fixtureWorkspace -WindowStyle Hidden -PassThru
  if (-not $script:launcherProcess.WaitForExit($TimeoutSec * 1000)) {
    Stop-Process -Id $script:launcherProcess.Id -Force -ErrorAction SilentlyContinue
    throw "crash guard fixture launcher did not finish within ${TimeoutSec}s"
  }
  $launcherExitCode = $script:launcherProcess.ExitCode

  if (Test-Path -LiteralPath $pidRecordPath -PathType Leaf) {
    try {
      $pidRecord = Get-Content -LiteralPath $pidRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $pidRecord.pid) { $script:fixtureProcess = Get-Process -Id ([int]$pidRecord.pid) -ErrorAction SilentlyContinue }
    } catch { }
  }
  Stop-FixtureProcess

  $bootCount = 0
  if (Test-Path -LiteralPath $bootFile -PathType Leaf) { $bootCount = [int](Get-Content -LiteralPath $bootFile -Raw -Encoding UTF8) }
  $guardState = $null
  if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) { $guardState = Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
  $patchText = if (Test-Path -LiteralPath $guardPatchPath -PathType Leaf) { Get-Content -LiteralPath $guardPatchPath -Raw -Encoding UTF8 } else { '' }
  $startupIncident = $null
  if (Test-Path -LiteralPath $startupIncidentPath -PathType Leaf) { $startupIncident = Get-Content -LiteralPath $startupIncidentPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  $launcherLog = if (Test-Path -LiteralPath $launcherLogPath -PathType Leaf) { Get-Content -LiteralPath $launcherLogPath -Raw -Encoding UTF8 } else { '' }
  $quarantine = @($guardState.quarantined | Where-Object { [string]$_.moduleName -eq 'test-dsh-plugin' -or [string]$_.entryId -eq 'test-dsh-plugin' })
  $result = [ordered]@{
    startupIncidentPresent = $null -ne $startupIncident
    startupIncidentStatus = if ($null -eq $startupIncident) { $null } else { [string]$startupIncident.status }
    startupIncidentQuarantine = if ($null -eq $startupIncident) { @() } else { @($startupIncident.quarantinedPluginIds) }
    result = if ($launcherExitCode -eq 0 -and $bootCount -ge 2 -and $quarantine.Count -eq 1 -and $patchText -match "id: 'test-dsh-plugin'" -and $patchText -match 'disabled: true' -and $launcherLog -match 'DSH Web ready' -and $null -ne $startupIncident -and [string]$startupIncident.status -eq 'recovered' -and @($startupIncident.quarantinedPluginIds) -contains 'test-dsh-plugin') { 'PASS' } else { 'FAIL' }
    launcherExitCode = $launcherExitCode
    bootCount = $bootCount
    quarantinedPlugin = if ($quarantine.Count -eq 1) { 'test-dsh-plugin' } else { $null }
    guardStatePresent = Test-Path -LiteralPath $guardStatePath -PathType Leaf
    reversiblePatchPresent = ($patchText -match "id: 'test-dsh-plugin'") -and ($patchText -match 'disabled: true')
    startupReadyObserved = $launcherLog -match 'DSH Web ready'
    privacy = 'Temporary profile, workspace, runtime and state only; no real DSH_HOME is modified.'
  }
  $result | ConvertTo-Json -Depth 12
  if ($result.result -eq 'PASS') { exit 0 }
  exit 1
} catch {
  [ordered]@{ result = 'FAIL'; error = $_.Exception.Message; privacy = 'Temporary fixture only; no real DSH_HOME is modified.' } | ConvertTo-Json -Depth 8
  exit 1
} finally {
  Stop-FixtureProcess
  if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
  Remove-Item Env:DSH_CRASH_FIXTURE_BOOT_FILE -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
