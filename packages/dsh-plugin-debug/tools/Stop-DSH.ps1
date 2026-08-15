[CmdletBinding()]
param(
  [switch]$ShowWindow,
  [string]$StateRoot = '',
  [string]$Profile = 'web',
  [int]$Port = 3080
)

$ErrorActionPreference = 'Stop'
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$explicitStateRoot = -not [string]::IsNullOrWhiteSpace($StateRoot)
if (-not $explicitStateRoot) {
  $StateRoot = Join-Path $LauncherRoot "state\$Profile-$Port"
}

function Select-PidFile {
  if ($explicitStateRoot) {
    return Join-Path $StateRoot 'dsh-web.pid.json'
  }

  $preferred = Join-Path $StateRoot 'dsh-web.pid.json'
  if (Test-Path -LiteralPath $preferred -PathType Leaf) { return $preferred }

  $legacy = Join-Path $LauncherRoot 'dsh-web.pid.json'
  if (Test-Path -LiteralPath $legacy -PathType Leaf) { return $legacy }

  $stateFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $LauncherRoot 'state') -Filter 'dsh-web.pid.json' -File -Recurse -ErrorAction SilentlyContinue |
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

try {
  $PidFile = Select-PidFile
  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
    Log 'no DSH PID file found; it may already be stopped.'
    exit 0
  }
  $record = Get-Content -Raw -LiteralPath $PidFile -Encoding UTF8 | ConvertFrom-Json
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

  $expected = [DateTime]::Parse([string]$record.startedAt).ToUniversalTime()
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
