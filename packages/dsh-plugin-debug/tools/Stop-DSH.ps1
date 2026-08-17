[CmdletBinding()]
param(
  [switch]$ShowWindow,
  [string]$StateRoot = '',
  [string]$Profile = 'web',
  [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateModulePath = Join-Path $LauncherRoot 'DSH-State.psm1'
Import-Module $StateModulePath -Force
$explicitStateRoot = -not [string]::IsNullOrWhiteSpace($StateRoot)
if (-not $explicitStateRoot) {
  $StateRoot = Resolve-DshDebugStateRoot -Profile $Profile -Port $Port
}

function Select-PidFile {
  if ($explicitStateRoot) {
    return Join-Path $StateRoot 'dsh-web.pid.json'
  }

  $preferred = Join-Path $StateRoot 'dsh-web.pid.json'
  if (Test-Path -LiteralPath $preferred -PathType Leaf) { return $preferred }

  $legacy = Join-Path $LauncherRoot 'dsh-web.pid.json'
  if (Test-Path -LiteralPath $legacy -PathType Leaf) { return $legacy }

  $stateRoots = @(
    (Join-Path (Resolve-DshDebugHome) 'dsh-plugin-debug\state'),
    (Join-Path $LauncherRoot 'state')
  ) | Select-Object -Unique
  $stateFiles = @(
    $stateRoots |
      Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
      ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'dsh-web.pid.json' -File -Recurse -ErrorAction SilentlyContinue } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -ExpandProperty FullName
  )
  if ($stateFiles.Count -eq 1) { return $stateFiles[0] }
  if ($stateFiles.Count -gt 1) {
    throw "multiple DSH instances found; pass -StateRoot explicitly: $($stateFiles -join ', ')"
  }
  return $preferred
}

$PidFile = $null
$LogDir = Join-Path $StateRoot 'logs'
$LauncherLog = Join-Path $LogDir 'launcher.log'

function Log([string]$Message) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  Add-Content -LiteralPath $LauncherLog -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
  if ($ShowWindow) { Write-Host $Message }
}

function Get-RawPidRecordTimestamp {
  param(
    [Parameter(Mandatory = $true)][string]$RawJson
  )

  # Windows PowerShell eagerly converts ISO JSON values to DateTime. Read the
  # two identity fields from the original text so their UTC offset is retained.
  foreach ($propertyName in @('processStartTimeUtc', 'startedAt')) {
    $pattern = '"' + [Regex]::Escape($propertyName) + '"\s*:\s*"(?<timestamp>[^"\\]*(?:\\.[^"\\]*)*)"'
    $match = [Regex]::Match(
      $RawJson,
      $pattern,
      [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if ($match.Success) {
      $value = $match.Groups['timestamp'].Value
      if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
  }
  return $null
}

try {
  $PidFile = Select-PidFile
  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
    Log 'no DSH PID file found; it may already be stopped.'
    exit 0
  }
  $rawPidRecord = Get-Content -Raw -LiteralPath $PidFile -Encoding UTF8
  $record = $rawPidRecord | ConvertFrom-Json
  if ($null -ne $record.stateRoot -and -not $explicitStateRoot) {
    $StateRoot = [string]$record.stateRoot
    $LogDir = Join-Path $StateRoot 'logs'
    $LauncherLog = Join-Path $LogDir 'launcher.log'
  }
  $targetPid = [int]$record.pid
  $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    Remove-Item -LiteralPath $PidFile -Force
    Log "PID $targetPid no longer exists; stale PID file removed."
    exit 0
  }

  # The launcher writes ISO-8601 UTC timestamps. DateTime.Parse can treat a
  # trailing Z as local time on Windows PowerShell and then apply the local
  # offset a second time, falsely reporting a reused PID. Prefer the precise
  # child start timestamp and preserve its offset with DateTimeOffset.
  $recordedStart = Get-RawPidRecordTimestamp -RawJson $rawPidRecord
  if ([string]::IsNullOrWhiteSpace($recordedStart)) {
    throw 'PID record does not contain a usable processStartTimeUtc or startedAt timestamp.'
  }
  $expected = [DateTimeOffset]::Parse(
    $recordedStart,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
  ).UtcDateTime
  $actual = $process.StartTime.ToUniversalTime()
  if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 10) {
    throw "PID $targetPid appears reused by another process; it was not stopped."
  }

  & taskkill.exe /PID $targetPid /T /F | Out-Null
  $taskkillCode = $LASTEXITCODE
  if ($taskkillCode -ne 0) {
    throw "taskkill failed for PID $targetPid with exit code $taskkillCode; PID file was kept."
  }
  Remove-Item -LiteralPath $PidFile -Force
  Log "requested DSH process-tree stop PID=$targetPid (taskkill exit code $taskkillCode)."
  exit 0
} catch {
  try { Log "ERROR $($_.Exception.Message)" } catch { }
  if ($ShowWindow) { Write-Error $_.Exception.Message }
  exit 1
}
