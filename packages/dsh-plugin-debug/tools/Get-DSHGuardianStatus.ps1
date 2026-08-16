[CmdletBinding()]
param(
  [string]$Url = 'http://127.0.0.1:3081/api/dsh-plugin-debug/guardian/status',
  [string]$InputPath = '',
  [ValidateRange(1, 30)][int]$TimeoutSec = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-GuardianStatus {
  if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw 'guardian status input does not exist' }
    $file = Get-Item -LiteralPath $InputPath -Force
    if ($file.Length -gt 1MB) { throw 'guardian status input exceeds the bounded file size' }
    return (Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  }
  return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec $TimeoutSec
}

try {
  $status = Read-GuardianStatus
  if ($null -eq $status -or $status.ok -ne $true -or $status.kind -ne 'dsh-plugin-debug-guardian-status') {
    throw 'guardian status response is invalid'
  }
  $safe = [bool]$status.safeToRestart
  [ordered]@{
    kind = 'dsh-plugin-debug-guardian-check'
    result = if ($safe) { 'SAFE_TO_RESTART' } else { 'BUSY_DO_NOT_RESTART' }
    safeToRestart = $safe
    activeSessions = [int]$status.activeSessions
    inFlightOperations = [int]$status.inFlightOperations
    readOnly = $true
    actions = @('detect', 'guide', 'report')
    terminatesTasks = $false
    stopsProcesses = $false
    restartsHost = $false
    disablesPlugins = $false
    source = if ([string]::IsNullOrWhiteSpace($InputPath)) { 'loopback-status-route' } else { 'offline-fixture' }
  } | ConvertTo-Json -Depth 12
  if (-not $safe) { exit 2 }
  exit 0
} catch {
  [ordered]@{
    kind = 'dsh-plugin-debug-guardian-check'
    result = 'UNAVAILABLE'
    safeToRestart = $false
    readOnly = $true
    error = 'guardian status could not be read'
    actions = @('detect', 'guide', 'report')
    terminatesTasks = $false
    stopsProcesses = $false
    restartsHost = $false
    disablesPlugins = $false
  } | ConvertTo-Json -Depth 12
  exit 1
}
