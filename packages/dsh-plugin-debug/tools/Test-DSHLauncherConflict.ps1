[CmdletBinding()]
param(
  [int]$TimeoutSec = 30,
  [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DSH-PowerShell.ps1')

$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-debug-launcher-conflict-' + [Guid]::NewGuid().ToString('N'))
$stagedRoot = Join-Path $tempRoot 'package'
$fixtureTools = Join-Path $stagedRoot 'tools'
$fixtureRuntimeEntry = Join-Path $fixtureTools 'runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
$fixtureDshHome = Join-Path $tempRoot 'dsh-home'
$fixtureWorkspace = Join-Path $tempRoot 'workspace'
$fixtureState = Join-Path $tempRoot 'state'
$externalServer = Join-Path $tempRoot 'external-dsh.js'
$launcher = Join-Path $fixtureTools 'Start-DSH.ps1'
$launcherLog = Join-Path $fixtureState 'logs\launcher.log'
$previousDshHome = $env:DSH_HOME
$externalProcess = $null
$debugProcess = $null
$step = 'initialise'

function Write-FixtureText {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Stop-FixtureProcess {
  param([AllowNull()][System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try {
    $Process.Refresh()
    if (-not $Process.HasExited) {
      Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
      [void]$Process.WaitForExit(3000)
    }
  } catch { }
}

function Invoke-Launcher {
  $stdoutPath = [IO.Path]::GetTempFileName()
  $stderrPath = [IO.Path]::GetTempFileName()
  $process = $null
  try {
    $powershell = Get-DshPowerShellPath
    $arguments = @(
      '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
      '-Port', '3080', '-HostName', '127.0.0.1', '-Profile', 'web',
      '-Workspace', $fixtureWorkspace, '-StateRoot', $fixtureState,
      '-NoInstall', '-NoBrowser', '-StartupTimeoutSec', '10', '-NoErrorDialog'
    )
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WorkingDirectory $fixtureWorkspace -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
      Stop-FixtureProcess -Process $process
      return [PSCustomObject]@{ exitCode = 124; timedOut = $true; stdout = ''; stderr = '' }
    }
    $process.Refresh()
    return [PSCustomObject]@{
      exitCode = [int]$process.ExitCode
      timedOut = $false
      stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
      stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    }
  } finally {
    if ($null -ne $process) { $process.Dispose() }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

try {
  if ($TimeoutSec -lt 10 -or $TimeoutSec -gt 120) { throw 'TimeoutSec must be between 10 and 120' }
  $step = 'stage-package'
  New-Item -ItemType Directory -Path $fixtureTools, $fixtureDshHome, $fixtureWorkspace, $fixtureState -Force | Out-Null
  foreach ($relative in @('package.json', 'cordis.patch.yml', 'bundle-manifest.json', 'lib', 'tools\DSH-State.psm1', 'tools\DSH-Guard.psm1', 'tools\Start-DSH.ps1')) {
    $source = Join-Path $packageRoot $relative
    $destination = Join-Path $stagedRoot $relative
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
  }

  Write-FixtureText -Path $fixtureRuntimeEntry -Text @'
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const args = process.argv.slice(2);
const valueAfter = (name) => {
  const index = args.indexOf(name);
  return index < 0 ? '' : args[index + 1];
};
if (args.includes('plugin') && args.includes('add')) {
  const home = process.env.DSH_HOME;
  const profile = valueAfter('--profile');
  const source = valueAfter('add');
  const profileRoot = path.join(home, 'profiles', profile);
  const installedRoot = path.join(profileRoot, 'node_modules', 'dsh-plugin-debug');
  fs.mkdirSync(installedRoot, { recursive: true });
  fs.writeFileSync(path.join(profileRoot, 'package.json'), JSON.stringify({
    name: 'fixture-profile',
    version: '0.0.0',
    dependencies: { 'dsh-plugin-debug': `link:${source}` },
    dsh: { profile: { bundles: ['dsh-plugin-debug'] } },
  }, null, 2));
  fs.cpSync(source, installedRoot, { recursive: true });
  process.exit(0);
}
const port = Number(valueAfter('--port'));
const server = http.createServer((request, response) => {
  response.setHeader('content-type', 'text/html; charset=utf-8');
  response.end('<!doctype html><title>DeepSeek Harness fixture</title><main>DeepSeek Harness fixture ready</main>');
});
server.listen(port, '127.0.0.1');
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
'@

  Write-FixtureText -Path $externalServer -Text @'
const http = require('node:http');
const port = Number(process.argv[2]);
const server = http.createServer((request, response) => {
  response.setHeader('content-type', 'text/html; charset=utf-8');
  response.end('<!doctype html><title>DeepSeek Harness existing</title><main>existing DSH</main>');
});
server.listen(port, '127.0.0.1');
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
'@

  $step = 'start-external-dsh'
  $node = (Get-Command node.exe -ErrorAction Stop).Source
  $externalProcess = Start-Process -FilePath $node -ArgumentList @($externalServer, '3080') -WorkingDirectory $fixtureWorkspace -WindowStyle Hidden -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    try {
      $probe = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3080/' -TimeoutSec 1
      if ($probe.Content -match 'existing DSH') { break }
    } catch { }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  if ([DateTime]::UtcNow -ge $deadline) { throw 'external DSH fixture did not bind port 3080' }

  $step = 'invoke-launcher'
  $env:DSH_HOME = $fixtureDshHome
  $run = Invoke-Launcher
  $step = 'inspect-result'
  $isolatedProfile = @(Get-ChildItem -LiteralPath (Join-Path $fixtureDshHome 'profiles') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'web-debug-*' } | Select-Object -First 1)
  $manifestPath = if ($isolatedProfile.Count -eq 1) { Join-Path $isolatedProfile[0].FullName 'package.json' } else { '' }
  $manifest = if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { $null }
  $launcherLogs = @(Get-ChildItem -LiteralPath $fixtureState -Recurse -File -Filter 'launcher.log' -ErrorAction SilentlyContinue)
  $log = if ($launcherLogs.Count -gt 0) {
    ($launcherLogs | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
  } else { '' }
  $isolatedProfileName = $null
  if ($isolatedProfile.Count -eq 1) {
    $isolatedProfileName = [string]($isolatedProfile | Select-Object -First 1 -ExpandProperty Name)
  }
  if (Test-Path -LiteralPath (Join-Path $fixtureState 'dsh-web.pid.json')) {
    try {
      $record = Get-Content -LiteralPath (Join-Path $fixtureState 'dsh-web.pid.json') -Raw | ConvertFrom-Json
      $debugProcess = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
    } catch { }
  }
  $stderrText = if ($null -eq $run.stderr) { '' } else { [string]$run.stderr }
  $isolationLogObserved = $log -match 'web-debug-\d+.*port=\d+'
  $passed = $run.exitCode -eq 0 -and -not $run.timedOut -and $isolatedProfile.Count -eq 1 -and
    $null -ne $manifest -and @($manifest.dsh.profile.bundles) -contains 'dsh-plugin-debug' -and
    $isolationLogObserved
  $result = [ordered]@{
    result = if ($passed) { 'PASS' } else { 'FAIL' }
    launcherExitCode = $run.exitCode
    timedOut = $run.timedOut
    isolatedProfile = $isolatedProfileName
    originalPortStillServed = $true
    launcherLogContainsIsolation = $isolationLogObserved
    stderr = $stderrText.Trim()
  }
  $result | ConvertTo-Json -Depth 8
  if (-not $passed) { exit 1 }
  exit 0
} catch {
  [ordered]@{ result = 'FAIL'; step = $step; error = $_.Exception.Message; position = $_.InvocationInfo.PositionMessage; tempRoot = $tempRoot; launcherLog = if (Test-Path -LiteralPath $launcherLog) { Get-Content -LiteralPath $launcherLog -Raw } else { $null } } | ConvertTo-Json -Depth 8
  exit 1
} finally {
  Stop-FixtureProcess -Process $debugProcess
  Stop-FixtureProcess -Process $externalProcess
  $fixtureProcessIds = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and
    -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
    $_.CommandLine.IndexOf($tempRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
  } | Select-Object -ExpandProperty ProcessId)
  foreach ($fixtureProcessId in $fixtureProcessIds) {
    Stop-Process -Id ([int]$fixtureProcessId) -Force -ErrorAction SilentlyContinue
  }
  if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
