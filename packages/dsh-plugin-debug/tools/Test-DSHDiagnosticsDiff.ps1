[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'DSH-PowerShell.ps1')
$packageRoot = Split-Path -Parent $toolRoot
$diffScript = Join-Path $toolRoot 'DSH-DiagnosticsDiff.ps1'
$debugEntry = Join-Path $packageRoot 'Debug-DSH.ps1'
$provenanceEntry = Join-Path $packageRoot 'DSH-Provenance.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-diagnostics-diff-' + [guid]::NewGuid().ToString('N'))

function Assert-DshDiagnosticsDiff {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-DshDiagnosticsDiffJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Arguments)
  $stderrPath = Join-Path $tempRoot ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
  try {
    $raw = & (Get-DshPowerShellPath) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -and (Test-Path -LiteralPath $stderrPath -PathType Leaf)) {
      $text = (Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8).Trim()
    }
    $value = $null
    try { $value = $text | ConvertFrom-Json } catch { }
    return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
  } finally {
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Write-DshDiagnosticsDiffFixture {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $beforePath = Join-Path $tempRoot 'before.json'
  $afterPath = Join-Path $tempRoot 'after.json'
  $unchangedPath = Join-Path $tempRoot 'unchanged.json'
  $unsafePath = Join-Path $tempRoot 'unsafe.json'
  $invalidPath = Join-Path $tempRoot 'invalid.json'
  $diffOutputPath = Join-Path $tempRoot 'diff-report.json'

  $privacy = [ordered]@{
    rawToolArgumentsStored = $false
    rawToolResultsStored = $false
    credentialsStored = $false
    networkPayloadSent = $false
    modelPromptSent = $false
    toolExecuted = $false
    note = 'Metadata-only report; raw Tool arguments are omitted.'
  }
  $before = [ordered]@{
    kind = 'dsh-debug-incident'
    schemaVersion = 1
    result = 'PARTIAL'
    issueCodes = @('PLUGIN_TIMEOUT', 'RUNTIME_WARNING')
    collection = [ordered]@{ readOnlyCollection = $true; writesLocalReport = $true; networkPayloadSent = $false; modelPromptSent = $false; toolExecuted = $false }
    componentStatusCounts = [ordered]@{ complete = 2; partial = 1; unavailable = 0; failed = 0 }
    components = [ordered]@{
      diagnostics = [ordered]@{ status = 'PARTIAL'; failedPluginCount = 2; errorObjectObserved = $false; runtimeEvidenceStatus = 'degraded' }
      startup = [ordered]@{ status = 'PASS'; startupStatus = 'healthy'; restartCount = 0 }
    }
    privacy = $privacy
  }
  $after = [ordered]@{
    kind = 'dsh-debug-incident'
    schemaVersion = 1
    result = 'PASS'
    issueCodes = @('PLUGIN_RECOVERED', 'RUNTIME_WARNING')
    collection = [ordered]@{ readOnlyCollection = $true; writesLocalReport = $true; networkPayloadSent = $false; modelPromptSent = $false; toolExecuted = $false }
    componentStatusCounts = [ordered]@{ complete = 3; partial = 0; unavailable = 0; failed = 0 }
    components = [ordered]@{
      diagnostics = [ordered]@{ status = 'PASS'; failedPluginCount = 0; errorObjectObserved = $false; runtimeEvidenceStatus = 'usable' }
      startup = [ordered]@{ status = 'PARTIAL'; startupStatus = 'recovered'; restartCount = 1 }
      health = [ordered]@{ status = 'PASS' }
    }
    privacy = $privacy
  }
  Write-DshDiagnosticsDiffFixture -Path $beforePath -Value $before
  Write-DshDiagnosticsDiffFixture -Path $afterPath -Value $after
  Write-DshDiagnosticsDiffFixture -Path $unchangedPath -Value ($before | ConvertTo-Json -Depth 20 | ConvertFrom-Json)

  $direct = Invoke-DshDiagnosticsDiffJson -Path $diffScript -Arguments @('-BeforePath', $beforePath, '-AfterPath', $afterPath, '-OutputPath', $diffOutputPath)
  Assert-DshDiagnosticsDiff ($direct.exitCode -eq 0 -and $direct.value.result -eq 'PASS') 'direct diagnostics diff did not return PASS'
  Assert-DshDiagnosticsDiff ($direct.value.comparisonStatus -eq 'CHANGED') 'changed fixture was not marked CHANGED'
  Assert-DshDiagnosticsDiff ([int]$direct.value.summary.changedCount -gt 0 -and [int]$direct.value.summary.addedCount -gt 0) 'field-level changed/added counts were not reported'
  Assert-DshDiagnosticsDiff ([int]$direct.value.summary.statusChangeCount -ge 3) 'status changes were not reported for top-level and component statuses'
  Assert-DshDiagnosticsDiff ($direct.value.issueChanges.issueCodes.added -contains 'PLUGIN_RECOVERED' -and $direct.value.issueChanges.issueCodes.removed -contains 'PLUGIN_TIMEOUT') 'issue code add/remove delta was incorrect'
  Assert-DshDiagnosticsDiff ($direct.value.issueChanges.issueCodes.changed -eq $true) 'issue code change flag was not set'
  Assert-DshDiagnosticsDiff ($direct.value.offline -eq $true -and $direct.value.networkAccessed -eq $false -and $direct.value.readOnly -eq $true) 'diff crossed its offline/read-only contract'
  Assert-DshDiagnosticsDiff (Test-Path -LiteralPath $diffOutputPath -PathType Leaf) 'explicit diff output was not written'
  Assert-DshDiagnosticsDiff ((Get-Content -LiteralPath $diffOutputPath -Raw -Encoding UTF8) -notmatch 'before\.json|after\.json') 'diff output leaked input paths'

  $unchanged = Invoke-DshDiagnosticsDiffJson -Path $diffScript -Arguments @('-BeforePath', $beforePath, '-AfterPath', $unchangedPath)
  Assert-DshDiagnosticsDiff ($unchanged.exitCode -eq 0 -and $unchanged.value.comparisonStatus -eq 'UNCHANGED' -and [int]$unchanged.value.summary.changedCount -eq 0) 'identical metadata reports were not stable/UNCHANGED'

  $unsafe = [ordered]@{
    kind = 'dsh-debug-incident'
    schemaVersion = 1
    result = 'PASS'
    message = 'PRIVATE_RAW_MESSAGE'
    path = 'C:\private\secret.json'
    privacy = $privacy
  }
  Write-DshDiagnosticsDiffFixture -Path $unsafePath -Value $unsafe
  $manual = Invoke-DshDiagnosticsDiffJson -Path $diffScript -Arguments @('-BeforePath', $unsafePath, '-AfterPath', $afterPath)
  Assert-DshDiagnosticsDiff ($manual.exitCode -eq 0 -and $manual.value.result -eq 'MANUAL_REVIEW') 'sensitive input was not routed to MANUAL_REVIEW'
  Assert-DshDiagnosticsDiff ('SENSITIVE_FIELD_OBSERVED' -in @($manual.value.issueCodes)) 'sensitive field issue code was missing'
  Assert-DshDiagnosticsDiff ($manual.text -notmatch 'PRIVATE_RAW_MESSAGE|C:\\private\\secret\.json') 'manual review output leaked raw sensitive content or an absolute path'
  Assert-DshDiagnosticsDiff ($manual.value.privacy.metadataOnly -eq $true -and $manual.value.privacy.pathsStored -eq $false -and $manual.value.privacy.rawMessagesStored -eq $false) 'manual review did not preserve its metadata-only privacy contract'
  Assert-DshDiagnosticsDiff (@($manual.value.changes).Count -eq 0) 'manual review unexpectedly emitted field changes'

  Set-Content -LiteralPath $invalidPath -Value '{not-json' -Encoding UTF8
  $invalid = Invoke-DshDiagnosticsDiffJson -Path $diffScript -Arguments @('-BeforePath', $invalidPath, '-AfterPath', $afterPath)
  Assert-DshDiagnosticsDiff ($invalid.exitCode -ne 0 -and $invalid.value.result -eq 'FAIL' -and 'INPUT_INVALID' -in @($invalid.value.issueCodes)) 'invalid JSON did not fail closed'
  Assert-DshDiagnosticsDiff ($invalid.text -notmatch [regex]::Escape($invalidPath)) 'invalid input output leaked its filesystem path'

  $debug = Invoke-DshDiagnosticsDiffJson -Path $debugEntry -Arguments @('-Action', 'diagnostics-diff', '-InputPath', $beforePath, '-InputPath', $afterPath)
  Assert-DshDiagnosticsDiff ($debug.exitCode -eq 0 -and $debug.value.kind -eq 'dsh-diagnostics-diff' -and $debug.value.comparisonStatus -eq 'CHANGED') 'Debug-DSH diagnostics-diff forwarding failed'

  $provenance = Invoke-DshDiagnosticsDiffJson -Path $provenanceEntry -Arguments @('-Action', 'diagnostics-diff', '-BaselinePath', $beforePath, '-InputPath', $afterPath)
  Assert-DshDiagnosticsDiff ($provenance.exitCode -eq 0 -and $provenance.value.kind -eq 'dsh-diagnostics-diff' -and $provenance.value.comparisonStatus -eq 'CHANGED') 'DSH-Provenance diagnostics-diff forwarding failed'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-diagnostics-diff-test'
    offline = $true
    networkAccessed = $false
    metadataOnly = $true
    changedFieldCount = [int]$direct.value.summary.changedCount
    addedFieldCount = [int]$direct.value.summary.addedCount
    removedFieldCount = [int]$direct.value.summary.removedCount
    statusChangeCount = [int]$direct.value.summary.statusChangeCount
    issueCodeChangeCount = [int]$direct.value.summary.issueCodeChangeCount
    manualReview = $manual.value.result
    invalidInput = $invalid.value.result
    forwarding = [ordered]@{ debug = $debug.value.comparisonStatus; provenance = $provenance.value.comparisonStatus }
  } | ConvertTo-Json -Depth 15
  exit 0
} catch {
  [ordered]@{ result = 'FAIL'; kind = 'dsh-diagnostics-diff-test'; offline = $true; networkAccessed = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 12
  exit 1
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
