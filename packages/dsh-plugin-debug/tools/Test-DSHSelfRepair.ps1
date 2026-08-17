[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'DSH-PowerShell.ps1')
$repairScript = Join-Path $toolRoot 'DSH-SelfRepair.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-self-repair-' + [guid]::NewGuid().ToString('N'))
$dshHome = Join-Path $tempRoot 'dsh-home'
$profileRoot = Join-Path $dshHome 'profiles\fixture'
$stateRoot = Join-Path $tempRoot 'state'
$workspace = Join-Path $tempRoot 'workspace'
$diagnosticsPath = Join-Path $tempRoot 'diagnostics.json'
$planPath = Join-Path $tempRoot 'repair-plan.json'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-SelfRepair {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Invoke-SelfRepairJson {
  param([Parameter(Mandatory = $true)][hashtable]$Arguments)
  $tokens = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $Arguments.GetEnumerator()) {
    if ($entry.Value -is [bool] -or $entry.Value -is [System.Management.Automation.SwitchParameter]) {
      if ([bool]$entry.Value) { [void]$tokens.Add("-$($entry.Key)") }
      continue
    }
    [void]$tokens.Add("-$($entry.Key)")
    [void]$tokens.Add([string]$entry.Value)
  }
  $output = & (Get-DshPowerShellPath) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $repairScript @tokens 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  $value = $null
  try { $value = $text | ConvertFrom-Json } catch { }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

try {
  New-Item -ItemType Directory -Path $profileRoot, $stateRoot, $workspace -Force | Out-Null
  $manifest = [ordered]@{
    name = 'fixture-profile'
    version = '0.0.0'
    dependencies = [ordered]@{ 'test-dsh-plugin' = 'file:..\..\test-dsh-plugin' }
    dsh = [ordered]@{ profile = [ordered]@{ bundles = @() } }
  }
  $manifestText = $manifest | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText((Join-Path $profileRoot 'package.json'), $manifestText, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $workspace 'user.txt'), 'workspace must remain unchanged', [Text.UTF8Encoding]::new($false))
  [ordered]@{
    schemaVersion = 2
    pluginInventory = [ordered]@{
      failed = @([ordered]@{ entryId = 'test-dsh-plugin'; moduleName = 'test-dsh-plugin'; enabled = $true; fiberPhase = 'failed' })
    }
    toolCallObservation = [ordered]@{
      session = [ordered]@{ toolCallStats = [ordered]@{ errorResultCount = 1 } }
    }
    permission = [ordered]@{ settingsDefaultPreset = 'danger-full-access' }
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $diagnosticsPath -Encoding UTF8

  $run = Invoke-SelfRepairJson -Arguments @{
    Action = 'recover'
    Profile = 'fixture'
    Port = 1
    DshHome = $dshHome
    StateRoot = $stateRoot
    DiagnosticsPath = $diagnosticsPath
    PlanPath = $planPath
    Automatic = $true
  }
  $guardStatePath = Join-Path $stateRoot 'guard-state.json'
  $guardPatchPath = Join-Path $stateRoot 'guard.patch.yml'
  $guardState = if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) { Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
  $guardPatch = if (Test-Path -LiteralPath $guardPatchPath -PathType Leaf) { Get-Content -LiteralPath $guardPatchPath -Raw -Encoding UTF8 } else { '' }
  $manifestAfter = Get-Content -LiteralPath (Join-Path $profileRoot 'package.json') -Raw -Encoding UTF8

  Assert-SelfRepair ($run.exitCode -eq 0 -and $run.value.result -eq 'PASS') 'recover action did not return PASS'
  Assert-SelfRepair ($run.value.value.status -eq 'repaired-restart-required') 'recover action did not require an explicit restart after mutation'
  Assert-SelfRepair ($run.value.value.applied.status -eq 'applied' -and $run.value.value.applied.changed -eq $true) 'recover action did not apply the bounded quarantine mutation'
  Assert-SelfRepair ($run.value.value.safety.workspaceChanged -eq $false -and $run.value.value.safety.profileManifestChanged -eq $false) 'recover action crossed the workspace or Profile manifest boundary'
  Assert-SelfRepair ($run.value.value.safety.dangerFullAccessChanged -eq $false -and $run.value.value.safety.modelHasNoExecutionAuthority -eq $true) 'recover action weakened the permission or model authority boundary'
  Assert-SelfRepair (Test-Path -LiteralPath $planPath -PathType Leaf) 'recover action did not write its reviewed plan'
  Assert-SelfRepair ($null -ne $guardState -and @($guardState.quarantined).Count -eq 1 -and $guardState.quarantined[0].entryId -eq 'test-dsh-plugin') 'recover action did not quarantine the observed third-party plugin'
  Assert-SelfRepair ($guardPatch -match "id: 'test-dsh-plugin'" -and $guardPatch -match 'disabled: true') 'recover action did not write a disabled guard patch'
  $receiptPath = [string]$run.value.value.applied.receipt
  Assert-SelfRepair (-not [string]::IsNullOrWhiteSpace($receiptPath) -and (Test-Path -LiteralPath $receiptPath -PathType Leaf)) 'recover action did not write a rollback receipt'
  $patchBeforeConflict = [IO.File]::ReadAllText($guardPatchPath)
  [IO.File]::WriteAllText($guardPatchPath, $patchBeforeConflict + [Environment]::NewLine + '# user edit after repair' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  $conflict = Invoke-SelfRepairJson -Arguments @{ Action = 'revert'; ReceiptPath = $receiptPath; Force = $true }
  Assert-SelfRepair ($conflict.exitCode -ne 0 -and $conflict.text -match 'ROLLBACK_CONFLICT') 'revert did not fail closed after a post-image edit'
  [IO.File]::WriteAllText($guardPatchPath, $patchBeforeConflict, [Text.UTF8Encoding]::new($false))
  $revert = Invoke-SelfRepairJson -Arguments @{ Action = 'revert'; ReceiptPath = $receiptPath; Force = $true }
  Assert-SelfRepair ($revert.exitCode -eq 0 -and $revert.value.result -eq 'PASS') 'revert did not restore a receipt with unchanged post-images'
  Assert-SelfRepair (-not (Test-Path -LiteralPath $guardStatePath -PathType Leaf) -and -not (Test-Path -LiteralPath $guardPatchPath -PathType Leaf)) 'revert left generated guard files behind'

  $maliciousPlanPath = Join-Path $tempRoot 'malicious-repair-plan.json'
  [ordered]@{
    schemaVersion = 2
    incidentId = 'fixture-incident'
    evidenceHash = ('a' * 64)
    observedCandidateIds = @()
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    expiresAt = (Get-Date).ToUniversalTime().AddHours(1).ToString('o')
    profile = 'fixture'
    mode = 'advisory'
    operations = @()
    safety = [ordered]@{ metadata = [ordered]@{ command = 'Remove-Item' } }
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $maliciousPlanPath -Encoding UTF8
  $maliciousApply = Invoke-SelfRepairJson -Arguments @{ Action = 'apply'; Profile = 'fixture'; DshHome = $dshHome; StateRoot = $stateRoot; PlanPath = $maliciousPlanPath }
  Assert-SelfRepair ($maliciousApply.exitCode -ne 0 -and $maliciousApply.text -match 'forbidden property') 'malicious nested repair property was not rejected'
  Assert-SelfRepair ($manifestAfter -eq $manifestText) 'recover action modified the Profile manifest'
  Assert-SelfRepair ((Get-Content -LiteralPath (Join-Path $workspace 'user.txt') -Raw -Encoding UTF8) -eq 'workspace must remain unchanged') 'recover action modified the workspace'
} catch {
  [void]$failures.Add("unhandled: $($_.Exception.Message)")
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[ordered]@{
  result = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
  kind = 'dsh-self-repair-test'
  offline = $true
  networkAccessed = $false
  workspaceChanged = $false
  profileManifestChanged = $false
  failures = @($failures)
} | ConvertTo-Json -Depth 15
if ($failures.Count -gt 0) { exit 1 }
exit 0
