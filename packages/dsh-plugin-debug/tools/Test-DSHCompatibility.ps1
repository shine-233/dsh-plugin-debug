[CmdletBinding()]
param(
  [switch]$ConfirmRealDsh,
  [string]$BaseUrl = 'http://127.0.0.1:3080',
  [string]$ExpectedPluginId = 'dsh-plugin-debug',
  [int]$TimeoutSec = 8,
  [string]$OutputPath = '',
  [switch]$StartPinnedRuntime,
  [string]$RuntimeRoot = ''
)

# This lane probes a real DSH instance only after an explicit confirmation. It
# never starts a fixture, sends a model request, installs a plugin, edits a
# user Profile, or stops a process it did not start. `-StartPinnedRuntime` is
# the one exception: it starts the pinned launcher in a temporary DSH_HOME and
# cleans up that process and directory in Complete-Summary. Requiring the
# confirmation keeps ordinary CI and local checks offline and prevents a fake
# fixture from being reported as compatibility evidence.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $toolRoot
$guardPath = Join-Path $toolRoot 'DSH-Guard.psm1'
$script:StartedRuntime = $false
$script:StartedStateRoot = ''
$script:StartedTempRoot = ''
$script:StartedProcess = $null
$script:OriginalDshHome = [Environment]::GetEnvironmentVariable('DSH_HOME', 'Process')
$script:OriginalRuntimeRoot = [Environment]::GetEnvironmentVariable('DSH_RUNTIME_ROOT', 'Process')
$script:CompatibilityPowerShell = $null

function New-Summary {
  param([string]$Result)
  [ordered]@{
    schemaVersion = 1
    result = $Result
    usedRealDsh = [bool]$ConfirmRealDsh
    usedRealDshHome = (-not [string]::IsNullOrWhiteSpace([string]$env:DSH_HOME)) -and (Test-Path -LiteralPath $env:DSH_HOME -PathType Container)
    usedRealDshPort = $false
    baseUrl = $BaseUrl
    expectedPluginId = $ExpectedPluginId
    web = [ordered]@{ reachable = $false; statusCode = $null; isDsh = $false }
    host = [ordered]@{ reachable = $false; fields = @() }
    inventory = [ordered]@{ reachable = $false; count = 0; expectedPluginObserved = $false }
    modelRequests = $false
    processStarted = $false
    cleanupPerformed = $false
    checks = @()
    error = $null
  }
}

function Write-Summary {
  param([Parameter(Mandatory = $true)]$Summary)
  $json = $Summary | ConvertTo-Json -Depth 20
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
  }
  Write-Output $json
}

function Stop-StartedRuntime {
  if (-not $script:StartedRuntime) { return }
  try {
    $stopScript = Join-Path $toolRoot 'Stop-DSH.ps1'
    if ((Test-Path -LiteralPath $stopScript -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($script:StartedStateRoot)) {
      & $script:CompatibilityPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $stopScript -StateRoot $script:StartedStateRoot -Profile 'compatibility' -Port $script:StartedPort 2>$null
    }
  } catch { }
  try {
    if ($null -ne $script:StartedProcess) {
      $script:StartedProcess.Refresh()
      if (-not $script:StartedProcess.HasExited) { Stop-Process -Id $script:StartedProcess.Id -Force -ErrorAction SilentlyContinue }
    }
  } catch { }
  [Environment]::SetEnvironmentVariable('DSH_HOME', $script:OriginalDshHome, 'Process')
  [Environment]::SetEnvironmentVariable('DSH_RUNTIME_ROOT', $script:OriginalRuntimeRoot, 'Process')
  $env:DSH_HOME = $script:OriginalDshHome
  $env:DSH_RUNTIME_ROOT = $script:OriginalRuntimeRoot
  if (-not [string]::IsNullOrWhiteSpace($script:StartedTempRoot) -and (Test-Path -LiteralPath $script:StartedTempRoot -PathType Container)) {
    Remove-Item -LiteralPath $script:StartedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $script:StartedRuntime = $false
}

function Complete-Summary {
  param(
    [Parameter(Mandatory = $true)]$Summary,
    [Parameter(Mandatory = $true)][int]$ExitCode
  )
  Stop-StartedRuntime
  $Summary.cleanupPerformed = $Summary.processStarted -and -not $script:StartedRuntime
  Write-Summary $Summary
  exit $ExitCode
}

function Get-FreeLoopbackPort {
  $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try { $probe.Start(); return ([Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
}

function Start-PinnedRealDsh {
  param([Parameter(Mandatory = $true)]$Summary)
  $runtime = if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { Join-Path $toolRoot 'runtime' } else { [IO.Path]::GetFullPath($RuntimeRoot) }
  $runtimeEntry = Join-Path $runtime 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (-not (Test-Path -LiteralPath $runtimeEntry -PathType Leaf)) {
    throw "pinned runtime is not installed at $runtime; run npm ci --prefix tools/runtime --omit=dev --ignore-scripts first"
  }
  $script:StartedTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-real-compatibility-' + [Guid]::NewGuid().ToString('N'))
  $script:StartedStateRoot = Join-Path $script:StartedTempRoot 'state'
  $dshHome = Join-Path $script:StartedTempRoot 'dsh-home'
  New-Item -ItemType Directory -Path $script:StartedStateRoot, $dshHome -Force | Out-Null
  $script:StartedPort = Get-FreeLoopbackPort
  $script:CompatibilityPowerShell = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
  } else {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command powershell.exe -ErrorAction Stop }
    $command.Source
  }
  $startScript = Join-Path $toolRoot 'Start-DSH.ps1'
  $env:DSH_HOME = $dshHome
  $env:DSH_RUNTIME_ROOT = $runtime
  $arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript,
    '-Profile', 'compatibility', '-Port', [string]$script:StartedPort,
    '-NoBrowser', '-NoInstall', '-NoErrorDialog', '-StateRoot', $script:StartedStateRoot
  )
  $script:StartedProcess = Start-Process -FilePath $script:CompatibilityPowerShell -ArgumentList $arguments -PassThru -WindowStyle Hidden
  $script:StartedRuntime = $true
  $Summary.usedRealDshHome = Test-Path -LiteralPath $dshHome -PathType Container
  $Summary.usedRealDshPort = $true
  $Summary.processStarted = $true
  $Summary.baseUrl = "http://127.0.0.1:$($script:StartedPort)"
  $env:NO_PROXY = if ([string]::IsNullOrWhiteSpace([string]$env:NO_PROXY)) { '127.0.0.1,localhost,::1' } else { "$env:NO_PROXY,127.0.0.1,localhost,::1" }
  $env:no_proxy = $env:NO_PROXY
  $waitMilliseconds = [Math]::Max(30000, $TimeoutSec * 10000)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($waitMilliseconds)
  $ready = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri $Summary.baseUrl -Method Get -TimeoutSec ([Math]::Max(1, [Math]::Min(3, $TimeoutSec)))
      $body = [string]$response.Content
      if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and $body -match '(?i)dsh|deepseek|harness') {
        $ready = $true
        break
      }
    } catch { }
    try {
      $script:StartedProcess.Refresh()
      if ($script:StartedProcess.HasExited) {
        throw "pinned real DSH launcher exited before Web readiness with code $($script:StartedProcess.ExitCode)"
      }
    } catch {
      if ($_.Exception.Message -match '(?i)exited before Web readiness') { throw }
    }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) {
    throw "pinned real DSH launcher did not expose a DSH Web page within $([int]($waitMilliseconds / 1000)) seconds"
  }
}

$summary = New-Summary -Result 'UNAVAILABLE'
if (-not $ConfirmRealDsh) {
  $summary.error = 'real DSH compatibility is opt-in; rerun with -ConfirmRealDsh against a real DSH Web/Host instance'
  Complete-Summary -Summary $summary -ExitCode 2
}
if ([string]::IsNullOrWhiteSpace($ExpectedPluginId)) {
  $summary.result = 'FAIL'
  $summary.error = 'ExpectedPluginId cannot be empty'
  Complete-Summary -Summary $summary -ExitCode 1
}

try {
  if ($StartPinnedRuntime) {
    Start-PinnedRealDsh -Summary $summary
    $BaseUrl = $summary.baseUrl
  }
  $uri = $null
  if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
    throw 'BaseUrl must be an absolute HTTP(S) URL'
  }
  if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
    throw 'BaseUrl must not contain credentials, query, or fragment'
  }
  $summary.baseUrl = $uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
  $summary.usedRealDshPort = $uri.Port -gt 0
  # CI and some developer machines set a system HTTP proxy that returns a
  # synthetic 502 even for 127.0.0.1.  Keep loopback probes local; never use
  # this to bypass the explicit host allow-list in DSH-Guard for remote URLs.
  if ($uri.IsLoopback) {
    $env:NO_PROXY = if ([string]::IsNullOrWhiteSpace([string]$env:NO_PROXY)) { '127.0.0.1,localhost,::1' } else { "$env:NO_PROXY,127.0.0.1,localhost,::1" }
    $env:no_proxy = $env:NO_PROXY
  }
  Import-Module $guardPath -Force

  $webError = $null
  try {
    $webResponse = Invoke-WebRequest -UseBasicParsing -Uri $summary.baseUrl -Method Get -TimeoutSec $TimeoutSec
    $body = [string]$webResponse.Content
    $summary.web.reachable = $true
    $summary.web.statusCode = [int]$webResponse.StatusCode
    $summary.web.isDsh = ($body -match '(?i)dsh|deepseek|harness')
  } catch {
    $webError = $_.Exception.Message
    $responseProperty = $_.Exception.PSObject.Properties['Response']
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
      try {
        $summary.web.reachable = $true
        $summary.web.statusCode = [int]$responseProperty.Value.StatusCode
      } catch { }
    }
  }

  if (-not $summary.web.reachable) {
    $summary.error = "real DSH Web is unavailable: $webError"
    Complete-Summary -Summary $summary -ExitCode 2
  }
  if (-not $summary.web.isDsh) {
    $summary.result = 'FAIL'
    $summary.error = 'Web endpoint responded, but its body did not identify a DSH/DeepSeek Harness page'
    Complete-Summary -Summary $summary -ExitCode 1
  }

  $hostError = $null
  try {
    $hostValue = Invoke-DshGuardApi -BaseUrl $summary.baseUrl -Method 'host.describe' -Arguments @{} -TimeoutSec $TimeoutSec
    $summary.host.reachable = $true
    if ($null -ne $hostValue) {
      $summary.host.fields = @($hostValue.PSObject.Properties.Name | Sort-Object -Unique)
    }
  } catch {
    $hostError = $_.Exception.Message
  }
  if (-not $summary.host.reachable) {
    $summary.result = 'FAIL'
    $summary.error = "real DSH host.describe is unavailable: $hostError"
    Complete-Summary -Summary $summary -ExitCode 1
  }

  $inventoryError = $null
  try {
    # Invoke the real Host API directly.  Do not call the fixture-backed
    # Test-DSHLiveApi.ps1 or use any fallback inventory from local state.
    $inventoryValue = Invoke-DshGuardApi -BaseUrl $summary.baseUrl -Method 'pluginInventory/list' -Arguments @{} -TimeoutSec $TimeoutSec
    $entries = @()
    if ($null -ne $inventoryValue -and $null -ne $inventoryValue.PSObject.Properties['entries']) {
      $entries = @($inventoryValue.entries)
    }
    $summary.inventory.reachable = $true
    $summary.inventory.count = $entries.Count
    $summary.inventory.expectedPluginObserved = @($entries | Where-Object {
        [string]$_.entryId -eq $ExpectedPluginId -or
        [string]$_.moduleName -eq $ExpectedPluginId -or
        [string]$_.name -eq $ExpectedPluginId
      }).Count -gt 0
  } catch {
    $inventoryError = $_.Exception.Message
  }
  if (-not $summary.inventory.reachable) {
    $summary.result = 'FAIL'
    $summary.error = "real DSH pluginInventory/list is unavailable: $inventoryError"
    Complete-Summary -Summary $summary -ExitCode 1
  }
  if (-not $summary.inventory.expectedPluginObserved) {
    $summary.result = 'FAIL'
    $summary.error = "expected plugin '$ExpectedPluginId' was not observed in the real Host inventory"
    Complete-Summary -Summary $summary -ExitCode 1
  }

  $summary.result = 'PASS'
  $summary.checks = @(
    'real Web returned a DSH-identifying page',
    'real Host host.describe succeeded',
    "real Host inventory contained $ExpectedPluginId"
  )
  Complete-Summary -Summary $summary -ExitCode 0
} catch {
  $summary.result = if ($StartPinnedRuntime -and $_.Exception.Message -match '(?i)not installed|did not become ready|launcher failed') { 'UNAVAILABLE' } else { 'FAIL' }
  $summary.error = $_.Exception.Message
  $code = if ($summary.result -eq 'UNAVAILABLE') { 2 } else { 1 }
  Complete-Summary -Summary $summary -ExitCode $code
}
