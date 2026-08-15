[CmdletBinding()]
param(
  [ValidateSet('doctor', 'start', 'stop', 'diagnostics', 'health', 'snapshot', 'workbench', 'all')]
  [string]$Action = 'doctor',
  [string]$Profile = 'debug',
  [int]$Port = 3081,
  [string]$HostName = '127.0.0.1',
  [string]$Workspace = '',
  [string]$StateRoot = '',
  [switch]$NoBrowser,
  [switch]$NoInstall,
  [switch]$NoPluginInstall,
  [switch]$NoCrashGuard,
  [switch]$NoSupervisor,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$provenance = Join-Path $root 'DSH-Provenance.ps1'
$start = Join-Path $root 'Start-DSH-Debug.ps1'
$stop = Join-Path $root 'tools\Stop-DSH.ps1'
$workbench = Join-Path $root 'tools\DSH-Workbench.ps1'

function Invoke-Provenance {
  param([hashtable]$Arguments)
  $output = @(& $provenance @Arguments 2>&1)
  $output | Write-Output
  $status = [int]$LASTEXITCODE
  $text = $output -join "`n"
  if ($text -match '"result"\s*:\s*"FAIL"' -or $text -match '"healthy"\s*:\s*false') {
    $status = 1
  }
  exit $status
}

switch ($Action) {
  'start' {
    $args = @{
      Profile = $Profile; Port = $Port; HostName = $HostName; Workspace = $Workspace
      StateRoot = $StateRoot; NoBrowser = $NoBrowser; NoInstall = $NoInstall
      NoPluginInstall = $NoPluginInstall; NoCrashGuard = $NoCrashGuard
      NoSupervisor = $NoSupervisor
    }
    & $start @args
    exit ([int]$LASTEXITCODE)
  }
  'stop' {
    & $stop -Profile $Profile -Port $Port -StateRoot $StateRoot
    exit ([int]$LASTEXITCODE)
  }
  'diagnostics' { Invoke-Provenance @{ Action = 'diagnostics'; Profile = $Profile; Port = $Port; HostName = $HostName; StateRoot = $StateRoot } }
  'health' { Invoke-Provenance @{ Action = 'plugin-health'; Profile = $Profile; SkipApi = $true } }
  'snapshot' { Invoke-Provenance @{ Action = 'snapshot'; Workspace = $Workspace; SnapshotRoot = $StateRoot; Force = $Force } }
  'workbench' {
    & $workbench -Action diagnostics -Profile $Profile -Port $Port -StateRoot $StateRoot
    exit ([int]$LASTEXITCODE)
  }
  'all' {
    $results = [ordered]@{}
    $failed = $false
    foreach ($check in @('doctor', 'plugin-health', 'diagnostics')) {
      $output = & $provenance -Action $check -Profile $Profile -Port $Port -HostName $HostName -StateRoot $StateRoot 2>&1 | Out-String
      $results[$check] = $output.Trim()
      if ($output -match '"result"\s*:\s*"FAIL"' -or $output -match '"healthy"\s*:\s*false') { $failed = $true }
    }
    $results | ConvertTo-Json -Depth 20
    if ($failed) { exit 1 }
    exit 0
  }
  default { Invoke-Provenance @{ Action = 'doctor'; Profile = $Profile; Port = $Port; HostName = $HostName; StateRoot = $StateRoot } }
}
