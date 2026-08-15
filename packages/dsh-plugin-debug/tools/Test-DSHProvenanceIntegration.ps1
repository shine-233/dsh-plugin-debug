[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$toolRoot = Join-Path $packageRoot 'tools'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-plugin-debug-integration-' + [Guid]::NewGuid().ToString('N'))
$previousDshHome = $env:DSH_HOME

function Assert-DebugIntegration {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-JsonChild {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][hashtable]$Arguments,
    [int]$TimeoutSec = 30
  )
  $cli = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $Arguments.GetEnumerator()) {
    $value = $entry.Value
    if ($null -eq $value) { continue }
    [void]$cli.Add("-$($entry.Key)")
    if ($value -isnot [bool] -and $value -isnot [System.Management.Automation.SwitchParameter]) {
      [void]$cli.Add([string]$value)
    } elseif (-not [bool]$value) {
      $cli.RemoveAt($cli.Count - 1)
    }
  }
  $stdoutPath = [IO.Path]::GetTempFileName()
  $stderrPath = [IO.Path]::GetTempFileName()
  $process = $null
  try {
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $cli) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
      try { $process.Kill() } catch { }
      return [PSCustomObject]@{ exitCode = 124; text = 'child PowerShell timed out'; value = $null }
    }
    $process.Refresh()
    $parts = @(
      (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue),
      (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $text = ($parts -join "`n").Trim()
    $value = $null
    try { $value = $text | ConvertFrom-Json } catch { }
    return [PSCustomObject]@{ exitCode = [int]$process.ExitCode; text = $text; value = $value }
  } finally {
    if ($null -ne $process) { $process.Dispose() }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

try {
  $required = @(
    'package.json', 'bundle-manifest.json', 'cordis.patch.yml', 'lib\index.js', 'lib\client.js',
    'DSH-Provenance.ps1', 'Start-DSH-Combined.ps1', 'tools\Start-DSH.ps1',
    'tools\Install-DSH-Agents.ps1', 'tools\combined-agents.patch.yml',
    'tools\DSH-IncidentCorrelation.psm1', 'tools\Test-DSHIncidentCorrelation.ps1'
  )
  foreach ($relative in $required) {
    Assert-DebugIntegration (Test-Path -LiteralPath (Join-Path $packageRoot $relative) -PathType Leaf) "combined package is missing $relative"
  }

  $package = Get-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-DebugIntegration ($package.name -ceq 'dsh-plugin-debug') 'combined package name is not dsh-plugin-debug'
  Assert-DebugIntegration ($package.files -contains 'Start-DSH-Combined.ps1' -and $package.files -contains 'Start-DSH-Combined.cmd' -and $package.files -contains 'Start-DSH-Combined.vbs') 'combined launcher files are missing from package.files'

  $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'bundle-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $pointer = $manifest.features.pointerProvenance
  Assert-DebugIntegration ($manifest.package -ceq 'dsh-plugin-debug' -and $manifest.independentRuntime -eq $true) 'bundle manifest does not describe the combined package'
  Assert-DebugIntegration ($pointer.global -ceq '__DSH_PLUGIN_DEBUG__' -and $pointer.legacyGlobal -ceq '__DSH_PLUGIN_PROVENANCE__' -and $pointer.bridgeSelector -ceq 'meta[data-dsh-debug-bridge="1"]' -and $pointer.pointerEvent -ceq 'dsh-plugin-debug:pointer') 'bundle manifest does not expose canonical Debug and legacy provenance contracts'

  $clientText = Get-Content -LiteralPath (Join-Path $packageRoot 'lib\client.js') -Raw -Encoding UTF8
  foreach ($marker in @('__DSH_PLUGIN_DEBUG__', '__DSH_PLUGIN_PROVENANCE__', 'data-dsh-debug-bridge', 'data-dsh-provenance-bridge', 'const POINTER_EVENT', 'PLUGIN_ID', 'getPointerEvidence')) {
    Assert-DebugIntegration ($clientText.Contains($marker)) "client artifact is missing bridge marker: $marker"
  }
  $launcherText = Get-Content -LiteralPath (Join-Path $toolRoot 'Start-DSH.ps1') -Raw -Encoding UTF8
  Assert-DebugIntegration ($launcherText -notmatch '(?i)plugin.?store' -and $launcherText -notmatch '(?i)dsh-one-click') 'combined launcher still contains removed store or old one-click coupling'
  Assert-DebugIntegration ($launcherText -match '\[switch\]\$EnableAgents' -and $launcherText -match '\$AgentsPatch') 'combined launcher does not expose the Agent overlay boundary'

  # Stage only the public package shape and use a fake offline DSH CLI. This
  # proves the package installs as itself without a registry or real Profile.
  $stagedRoot = Join-Path $tempRoot 'package'
  New-Item -ItemType Directory -Path $stagedRoot -Force | Out-Null
  foreach ($relative in @('package.json', 'bundle-manifest.json', 'cordis.patch.yml', 'lib', 'tools', 'DSH-Provenance.ps1', 'Start-DSH-Combined.ps1')) {
    Copy-Item -LiteralPath (Join-Path $packageRoot $relative) -Destination (Join-Path $stagedRoot $relative) -Recurse -Force
  }
  $runtimeEntry = Join-Path $stagedRoot 'tools\runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
  New-Item -ItemType Directory -Path (Split-Path -Parent $runtimeEntry) -Force | Out-Null
  $fakeDsh = @'
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
if (args.includes('--dump-config')) { console.log('{}'); process.exit(0); }
if (!args.includes('plugin') || !args.includes('add')) process.exit(9);
const profile = args[args.indexOf('--profile') + 1];
const source = args[args.indexOf('add') + 1];
const home = process.env.DSH_HOME;
if (!home || !profile || !source) process.exit(10);
const profileRoot = path.join(home, 'profiles', profile);
const installedRoot = path.join(profileRoot, 'node_modules', 'dsh-plugin-debug');
fs.mkdirSync(installedRoot, { recursive: true });
fs.writeFileSync(path.join(profileRoot, 'package.json'), JSON.stringify({
  name: 'fixture-profile', version: '0.0.0',
  dependencies: { 'dsh-plugin-debug': `link:${source}` },
  dsh: { profile: { bundles: ['dsh-plugin-debug'] } },
}, null, 2));
fs.cpSync(source, installedRoot, { recursive: true });
'@
  [IO.File]::WriteAllText($runtimeEntry, $fakeDsh, [Text.UTF8Encoding]::new($false))

  $env:DSH_HOME = Join-Path $tempRoot 'dsh-home'
  $install = Invoke-JsonChild -ScriptPath (Join-Path $stagedRoot 'tools\Start-DSH.ps1') -Arguments @{ Profile = 'debug'; StateRoot = (Join-Path $tempRoot 'state'); InstallOnly = $true; NoInstall = $true }
  Assert-DebugIntegration ($install.exitCode -eq 0) "offline single-package install failed: $($install.text)"
  $profileManifestPath = Join-Path $env:DSH_HOME 'profiles\debug\package.json'
  $installedRoot = Join-Path $env:DSH_HOME 'profiles\debug\node_modules\dsh-plugin-debug'
  Assert-DebugIntegration (Test-Path -LiteralPath $profileManifestPath -PathType Leaf) 'offline install did not create the Profile manifest'
  $installedManifest = Get-Content -LiteralPath $profileManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-DebugIntegration (@($installedManifest.dsh.profile.bundles) -contains 'dsh-plugin-debug') 'Profile bundle list does not contain dsh-plugin-debug'
  Assert-DebugIntegration (Test-Path -LiteralPath (Join-Path $installedRoot 'lib\client.js') -PathType Leaf) 'offline install did not copy the combined client artifact'
  Assert-DebugIntegration (-not (Test-Path -LiteralPath (Join-Path $installedRoot 'dsh-plugin-store') -PathType Any)) 'removed plugin-store content entered the installed package'

  $correlation = Invoke-JsonChild -ScriptPath (Join-Path $stagedRoot 'tools\Test-DSHIncidentCorrelation.ps1') -Arguments @{}
  Assert-DebugIntegration ($correlation.exitCode -eq 0 -and $correlation.value.result -eq 'PASS' -and $correlation.value.networkAccessed -eq $false) 'offline incident-correlation fixture failed or crossed the network boundary'

  [ordered]@{
    result = 'PASS'
    package = 'dsh-plugin-debug'
    profile = 'debug'
    offlineInstall = 'PASS'
    canonicalClientBridge = 'PASS'
    legacyProvenanceBridge = 'PASS (compatibility alias)'
    combinedLauncher = 'PASS'
    agentOverlay = 'PASS'
    hostIncidentCorrelation = 'PASS (offline fixture)'
    pluginStoreCapability = 'REMOVED'
    tempRoot = if ($KeepTemp) { $tempRoot } else { $null }
  } | ConvertTo-Json -Depth 8
} catch {
  [ordered]@{ result = 'FAIL'; error = $_.Exception.Message; tempRoot = $tempRoot } | ConvertTo-Json -Depth 8
  exit 1
} finally {
  if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
  if (-not $KeepTemp) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
