[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $toolRoot 'DSH-Bisect.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-bisect-' + [guid]::NewGuid().ToString('N'))

function Assert-Bisect {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BisectSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)

  # Windows PowerShell installations can omit the Microsoft.PowerShell.Utility
  # module from a nested process. Keep the fixture deterministic without
  # treating that host-specific omission as a bisect failure.
  $hashCommand = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $hashCommand) {
    return ([string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToLowerInvariant()
  }

  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $inputPath = Join-Path $tempRoot 'input.json'
  $outputPath = Join-Path $tempRoot 'report.json'
  $fixture = [ordered]@{
    schemaVersion = 1
    profileManifest = [ordered]@{
      name = 'bisect-fixture'
      dependencies = [ordered]@{
        'safe-dsh-plugin' = 'file:..\safe-dsh-plugin'
        '@deepseek-ai/dsh-web-app' = '0.1.0'
        'utility-package' = '^1.0.0'
      }
    }
    inventory = @(
      [ordered]@{ entryId = 'include:safe-dsh-plugin'; moduleName = 'safe-dsh-plugin'; fiberPhase = 'failed'; enabled = $true },
      [ordered]@{ entryId = 'include:@deepseek-ai/dsh-web-app'; moduleName = '@deepseek-ai/dsh-web-app'; fiberPhase = 'failed'; enabled = $true },
      [ordered]@{ entryId = 'include:utility-package'; moduleName = 'utility-package'; fiberPhase = 'failed'; enabled = $true },
      [ordered]@{ entryId = 'include:unknown-dsh-plugin'; moduleName = 'unknown-dsh-plugin'; fiberPhase = 'failed'; enabled = $true }
    )
    failureEvidence = @(
      [ordered]@{ kind = 'fiber-failed'; pluginId = 'safe-dsh-plugin' },
      [ordered]@{ kind = 'startup-error'; moduleName = 'safe-dsh-plugin'; message = 'PRIVATE_ERROR_SHOULD_NOT_APPEAR' },
      [ordered]@{ kind = 'fiber-failed'; pluginId = '@deepseek-ai/dsh-web-app' },
      [ordered]@{ kind = 'startup-error'; moduleName = 'unknown-dsh-plugin'; command = 'Remove-Item' }
    )
  }
  $fixture | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inputPath -Encoding UTF8
  $before = Get-BisectSha256 -Path $inputPath
  $raw = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -InputPath $inputPath -OutputPath $outputPath 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($raw | Out-String).Trim()
  $report = $text | ConvertFrom-Json
  Assert-Bisect ($exitCode -eq 0 -and $report.result -eq 'PASS') "bisect plan did not return PASS: $text"
  Assert-Bisect ($report.offline -eq $true -and $report.networkAccessed -eq $false -and $report.readOnly -eq $true) 'bisect plan crossed its offline/read-only boundary'
  Assert-Bisect ($report.safety.profileChanged -eq $false -and $report.safety.workspaceChanged -eq $false -and $report.safety.commandsExecuted -eq $false -and $report.safety.autoDisabled -eq $false) 'bisect plan reported a mutation or execution'
  $safe = @($report.candidates | Where-Object { $_.classification -eq 'safe' })
  $protected = @($report.candidates | Where-Object { $_.classification -eq 'protected' })
  $ambiguous = @($report.candidates | Where-Object { $_.classification -eq 'ambiguous' })
  Assert-Bisect ($safe.Count -eq 1 -and $safe[0].pluginId -eq 'safe-dsh-plugin' -and $safe[0].mapping -eq 'stripped-include') 'safe third-party candidate was not mapped through the manifest'
  Assert-Bisect (@($protected | Where-Object { $_.pluginId -eq '@deepseek-ai/dsh-web-app' -and $_.reason -eq 'core-package' }).Count -eq 1) 'core DSH package was not protected'
  Assert-Bisect (@($protected | Where-Object { $_.pluginId -eq 'utility-package' -and $_.reason -eq 'non-plugin-dependency' }).Count -eq 1) 'ordinary dependency was not protected'
  Assert-Bisect (@($ambiguous | Where-Object { $_.pluginId -eq 'unknown-dsh-plugin' }).Count -eq 1) 'unmapped plugin was not marked ambiguous'
  Assert-Bisect (@($report.steps).Count -eq 3) 'bisect plan did not create baseline, candidate, and review steps'
  Assert-Bisect ((Get-BisectSha256 -Path $inputPath) -eq $before) 'bisect plan changed the input evidence'
  Assert-Bisect (Test-Path -LiteralPath $outputPath -PathType Leaf) 'bisect plan did not write the explicitly requested report'
  Assert-Bisect ((Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8) -notmatch 'PRIVATE_ERROR_SHOULD_NOT_APPEAR|Remove-Item') 'bisect report leaked raw evidence'
  [ordered]@{
    result = 'PASS'
    kind = 'dsh-plugin-bisect-test'
    offline = $true
    networkAccessed = $false
    candidateCounts = [ordered]@{ safe = $safe.Count; ambiguous = $ambiguous.Count; protected = $protected.Count }
    privacyContract = $true
    mutationContract = $true
  } | ConvertTo-Json -Depth 10
  exit 0
} catch {
  [ordered]@{ result = 'FAIL'; kind = 'dsh-plugin-bisect-test'; error = $_.Exception.Message } | ConvertTo-Json -Depth 10
  exit 1
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
