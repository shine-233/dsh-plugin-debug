[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'DSH-PowerShell.ps1')
Import-Module (Join-Path $root 'DSH-ResourcePressure.psm1') -Force

function Assert-ResourcePressure {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-ResourceProcessRows {
  param([int]$Count, [UInt64]$WorkingSetBytes)
  return @(
    1..$Count | ForEach-Object {
      [PSCustomObject]@{
        pid = 1000 + $_
        processName = 'node'
        workingSetBytes = $WorkingSetBytes
        startedAt = '2026-01-01T00:00:00.0000000Z'
      }
    }
  )
}

try {
  $memory = [PSCustomObject]@{
    totalPhysicalBytes = [UInt64]16GB
    freePhysicalBytes = [UInt64]8GB
    usedPhysicalBytes = [UInt64]8GB
  }
  $healthy = Get-DshResourcePressure -ProcessRows (New-ResourceProcessRows -Count 2 -WorkingSetBytes ([UInt64]64MB)) -MemorySnapshot $memory
  Assert-ResourcePressure ($healthy.status -eq 'healthy') 'healthy fixture was not healthy'
  Assert-ResourcePressure ($healthy.nodeProcessCount -eq 2) 'healthy fixture process count was wrong'

  $warning = Get-DshResourcePressure -ProcessRows (New-ResourceProcessRows -Count 30 -WorkingSetBytes ([UInt64]320MB)) -MemorySnapshot $memory
  Assert-ResourcePressure ($warning.status -eq 'warning') 'warning fixture was not warning'
  Assert-ResourcePressure ($warning.reasons.Count -ge 1) 'warning fixture did not record a reason'

  $critical = Get-DshResourcePressure -ProcessRows (New-ResourceProcessRows -Count 80 -WorkingSetBytes ([UInt64]160MB)) -MemorySnapshot $memory
  Assert-ResourcePressure ($critical.status -eq 'critical') 'critical fixture was not critical'
  Assert-ResourcePressure ($critical.topNodeProcesses.Count -eq 10) 'top process output was not bounded'

  $topPropertyNames = @($critical.topNodeProcesses | ForEach-Object { $_.PSObject.Properties.Name } | Sort-Object -Unique)
  foreach ($forbiddenProperty in @('CommandLine', 'commandLine', 'cwd', 'environment', 'arguments')) {
    Assert-ResourcePressure ($topPropertyNames -notcontains $forbiddenProperty) "resource report exposed forbidden property: $forbiddenProperty"
  }

  $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-resource-diagnostics-' + [guid]::NewGuid().ToString('N'))
  $fixtureProfile = Join-Path $fixtureRoot 'profiles\fixture'
  New-Item -ItemType Directory -Path $fixtureProfile -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixtureProfile 'package.json'), '{"name":"dsh-resource-fixture","dependencies":{},"dsh":{"profile":{"bundles":[]}}}', [Text.UTF8Encoding]::new($false))
  $diagnosticsPath = Join-Path $root 'Get-DSH-Diagnostics.ps1'
  $diagnosticsRaw = & (Get-DshPowerShellPath) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $diagnosticsPath -DshHome $fixtureRoot -Profile fixture -Port 32991 -StateRoot (Join-Path $fixtureRoot 'state') 2>&1
  $diagnosticsExitCode = $LASTEXITCODE
  $diagnostics = (($diagnosticsRaw | Out-String).Trim() | ConvertFrom-Json)
  Assert-ResourcePressure ($diagnosticsExitCode -eq 0) 'diagnostics integration exited non-zero'
  Assert-ResourcePressure ($null -ne $diagnostics.runtimeEvidence.resourcePressure) 'diagnostics did not expose resource pressure'
  Assert-ResourcePressure ([string]$diagnostics.runtimeEvidence.status -in @('usable', 'degraded', 'unavailable')) 'diagnostics runtime evidence status was invalid'
  $diagnosticsTopRows = @($diagnostics.runtimeEvidence.resourcePressure.topNodeProcesses)
  $diagnosticsTopPropertyNames = @($diagnosticsTopRows | ForEach-Object { $_.PSObject.Properties.Name } | Sort-Object -Unique)
  Assert-ResourcePressure ($diagnosticsTopPropertyNames -notcontains 'commandLine') 'diagnostics exposed a process command line'
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue

  [PSCustomObject]@{
    result = 'PASS'
    kind = 'dsh-resource-pressure-test'
    offline = $true
    networkAccessed = $false
    statuses = @($healthy.status, $warning.status, $critical.status)
    diagnosticsIntegration = $true
    boundedTopProcesses = $critical.topNodeProcesses.Count -eq 10
    privacyContract = $true
  } | ConvertTo-Json -Depth 12
  exit 0
} catch {
  [PSCustomObject]@{
    result = 'FAIL'
    kind = 'dsh-resource-pressure-test'
    offline = $true
    networkAccessed = $false
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 12
  exit 1
}
