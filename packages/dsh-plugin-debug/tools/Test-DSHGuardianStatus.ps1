[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$statusScript = Join-Path $toolRoot 'Get-DSHGuardianStatus.ps1'
$debugEntry = Join-Path (Split-Path -Parent $toolRoot) 'Debug-DSH.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-guardian-status-' + [Guid]::NewGuid().ToString('N'))
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-GuardianStatus {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Invoke-GuardianStatus {
  param(
    [string]$Path,
    [string]$EntryScript = '',
    [switch]$PublicEntry
  )
  $powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -eq $powerShell) { throw 'Windows PowerShell executable is required for the Guardian status fixture' }
  $scriptToRun = if ([string]::IsNullOrWhiteSpace($EntryScript)) { $statusScript } else { $EntryScript }
  $childArguments = if ($PublicEntry) {
    @('-Action', 'guardian-status', '-InputPath', $Path)
  } else {
    @('-InputPath', $Path)
  }
  $outputPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.out')
  $errorPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.err')
  try {
    $process = Start-Process -FilePath $powerShell.Source -ArgumentList (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptToRun) + $childArguments) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    $text = (Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8).Trim()
    return [PSCustomObject]@{ ExitCode = [int]$process.ExitCode; Text = $text; Value = ($text | ConvertFrom-Json) }
  } finally {
    Remove-Item -LiteralPath $outputPath,$errorPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-GuardianStatusThroughJsonHarness {
  param([Parameter(Mandatory = $true)][string]$Path)
  $childScript = [IO.Path]::GetFullPath($debugEntry)
  $childArgs = ConvertTo-Json -InputObject ([ordered]@{ Action = 'guardian-status'; InputPath = $Path }) -Compress -Depth 8
  $childCommand = '$parsedArgs = ConvertFrom-Json -InputObject $env:DSH_GUARDIAN_HARNESS_ARGS; $rawArgs = [System.Collections.Generic.List[string]]::new(); if ($null -ne $parsedArgs) { foreach ($property in $parsedArgs.PSObject.Properties) { $name = [string]$property.Name; $value = $property.Value; if ($value -is [bool]) { if ([bool]$value) { [void]$rawArgs.Add("-$name") }; continue }; if ($null -eq $value) { continue }; if ($value -is [System.Array]) { foreach ($item in $value) { if ($null -ne $item) { [void]$rawArgs.Add("-$name"); [void]$rawArgs.Add([string]$item) } } } else { [void]$rawArgs.Add("-$name"); [void]$rawArgs.Add([string]$value) } } }; & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $env:DSH_GUARDIAN_HARNESS_SCRIPT @rawArgs; $childExit = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }; exit $childExit'
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
  $outputPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.harness.out')
  $errorPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '.harness.err')
  $process = $null
  try {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['DSH_GUARDIAN_HARNESS_SCRIPT'] = $childScript
    $startInfo.EnvironmentVariables['DSH_GUARDIAN_HARNESS_ARGS'] = $childArgs
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'could not start JSON guardian harness' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; throw 'JSON guardian harness timed out' }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $text = if (-not [string]::IsNullOrWhiteSpace($stdout)) { $stdout.Trim() } else { $stderr.Trim() }
    return [PSCustomObject]@{ ExitCode = [int]$process.ExitCode; Text = $text; Value = ($text | ConvertFrom-Json) }
  } finally {
    if ($null -ne $process) { $process.Dispose() }
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

  $publicBusy = Invoke-GuardianStatus -Path $busyPath -EntryScript $debugEntry -PublicEntry
  Assert-GuardianStatus ($publicBusy.ExitCode -eq 2 -and $publicBusy.Value.result -eq 'BUSY_DO_NOT_RESTART') "public Guardian status entry did not fail closed (exit=$($publicBusy.ExitCode), result=$($publicBusy.Value.result))"

  $harnessBusy = Invoke-GuardianStatusThroughJsonHarness -Path $busyPath
  Assert-GuardianStatus ($harnessBusy.ExitCode -eq 2 -and $harnessBusy.Value.result -eq 'BUSY_DO_NOT_RESTART') "JSON harness Guardian status did not fail closed (exit=$($harnessBusy.ExitCode), result=$($harnessBusy.Value.result), text=$($harnessBusy.Text))"
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

[ordered]@{ result = 'PASS'; kind = 'dsh-plugin-debug-guardian-status-test'; offline = $true; networkAccessed = $false; readOnly = $true; safeState = $true; busyState = $true; publicEntry = $true; noTermination = $true } | ConvertTo-Json -Depth 12
exit 0
