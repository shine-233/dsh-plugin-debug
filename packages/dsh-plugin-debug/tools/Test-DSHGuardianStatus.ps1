[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$statusScript = Join-Path $toolRoot 'Get-DSHGuardianStatus.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-guardian-status-' + [Guid]::NewGuid().ToString('N'))
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-GuardianStatus {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Invoke-GuardianStatus {
  param([string]$Path)
  $powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -eq $powerShell) { throw 'Windows PowerShell executable is required for the Guardian status fixture' }
  $outputPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.out')
  $errorPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.err')
  try {
    $process = Start-Process -FilePath $powerShell.Source -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $statusScript, '-InputPath', $Path) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    $text = (Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8).Trim()
    return [PSCustomObject]@{ ExitCode = [int]$process.ExitCode; Text = $text; Value = ($text | ConvertFrom-Json) }
  } finally {
    Remove-Item -LiteralPath $outputPath,$errorPath -Force -ErrorAction SilentlyContinue
  }
}

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $idlePath = Join-Path $tempRoot 'idle.json'
  $busyPath = Join-Path $tempRoot 'busy.json'
  [ordered]@{
    ok = $true
    kind = 'dsh-plugin-debug-guardian-status'
    safeToRestart = $true
    activeSessions = 0
    inFlightOperations = 0
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $idlePath -Encoding UTF8
  [ordered]@{
    ok = $true
    kind = 'dsh-plugin-debug-guardian-status'
    safeToRestart = $false
    activeSessions = 1
    inFlightOperations = 2
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $busyPath -Encoding UTF8

  $idle = Invoke-GuardianStatus -Path $idlePath
  Assert-GuardianStatus ($idle.ExitCode -eq 0 -and $idle.Value.result -eq 'SAFE_TO_RESTART' -and $idle.Value.readOnly -eq $true) 'idle status was not accepted as read-only safe'
  Assert-GuardianStatus ($idle.Value.terminatesTasks -eq $false -and $idle.Value.restartsHost -eq $false) 'idle status exposed a mutating action'

  $busy = Invoke-GuardianStatus -Path $busyPath
  Assert-GuardianStatus ($busy.ExitCode -eq 2 -and $busy.Value.result -eq 'BUSY_DO_NOT_RESTART' -and $busy.Value.safeToRestart -eq $false) "busy status did not block restart (exit=$($busy.ExitCode), result=$($busy.Value.result), safe=$($busy.Value.safeToRestart))"
  Assert-GuardianStatus ($busy.Value.stopsProcesses -eq $false -and $busy.Value.disablesPlugins -eq $false) 'busy status exposed a termination action'
} catch {
  [void]$failures.Add("unhandled: $($_.Exception.Message)")
} finally {
  if (Test-Path -LiteralPath $tempRoot -PathType Container) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($failures.Count -gt 0) {
  [ordered]@{ result = 'FAIL'; kind = 'dsh-plugin-debug-guardian-status-test'; failures = @($failures); offline = $true; networkAccessed = $false } | ConvertTo-Json -Depth 12
  exit 1
}

[ordered]@{ result = 'PASS'; kind = 'dsh-plugin-debug-guardian-status-test'; offline = $true; networkAccessed = $false; readOnly = $true; safeState = $true; busyState = $true; noTermination = $true } | ConvertTo-Json -Depth 12
exit 0
