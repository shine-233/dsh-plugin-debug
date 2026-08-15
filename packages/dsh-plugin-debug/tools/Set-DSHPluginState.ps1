[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string]$DesiredState,
  [Parameter(Mandatory = $true)][string]$PluginId,
  [string]$Profile = 'web',
  [string]$DshHome = '',
  [string]$StateRoot = '',
  [int]$Port = 3080,
  [switch]$ClearQuarantine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'DSH-Guard.psm1') -Force

function Write-PluginStateResult {
  param([string]$Result, [string]$Message, $State = $null)
  [ordered]@{
    result = $Result
    message = $Message
    profile = $Profile
    pluginId = $PluginId
    patch = if ([string]::IsNullOrWhiteSpace($StateRoot)) { $null } else { Join-Path $StateRoot 'guard.patch.yml' }
    quarantined = if ($null -eq $State) { @() } else { @($State.quarantined | ForEach-Object { [string]$_.moduleName }) }
  } | ConvertTo-Json -Depth 12
}

try {
  if ($PluginId -match '^(?i:include):') { throw 'PluginId must be the Profile dependency id, not a runtime include:<id> inventory id.' }
  if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  }
  if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Join-Path $root "state\$Profile-$Port" }
  $manifestPath = Join-Path $DshHome "profiles\$Profile\package.json"
  $statePath = Join-Path $StateRoot 'guard-state.json'
  $patchPath = Join-Path $StateRoot 'guard.patch.yml'
  $manifest = Read-DshProfileManifest -Path $manifestPath
  if (-not (Test-DshGuardCandidate -ModuleName $PluginId -Manifest $manifest)) {
    throw "Plugin is not a safe third-party candidate or is not a direct dependency of the current Profile: $PluginId"
  }
  $state = Read-DshGuardState -Path $statePath -Profile $Profile
  $existing = @($state.quarantined | Where-Object { [string]$_.entryId -eq $PluginId -or [string]$_.moduleName -eq $PluginId })
  if ($DesiredState -eq 'disable') {
    if ($existing.Count -eq 0) {
      $candidate = [PSCustomObject]@{
        entryId = $PluginId
        inventoryEntryId = $null
        patchEntryId = $PluginId
        moduleName = $PluginId
        mapping = 'exact'
        fiberPhase = 'manual'
        reason = 'manual-plugin-disable'
        attribution = 'explicit-user'
      }
      Add-DshGuardQuarantine -State $state -Candidate $candidate | Out-Null
    }
    $message = "Recorded disable for $PluginId. Start with -EnableCrashGuard to load this reversible patch."
  } else {
    if ($existing.Count -gt 0) {
      $blocked = @($existing | Where-Object { [string]$_.reason -ne 'manual-plugin-disable' })
      if ($blocked.Count -gt 0 -and -not $ClearQuarantine) {
        throw "The plugin is quarantined after a crash. Pass -ClearQuarantine only if you explicitly want to restore it: $PluginId"
      }
      $state.quarantined = @($state.quarantined | Where-Object {
          -not ([string]$_.entryId -eq $PluginId -or [string]$_.moduleName -eq $PluginId)
        })
    }
    $message = "Removed the local disable patch for $PluginId. Restart the Profile if DSH is already running."
  }
  $state.lastRun = [PSCustomObject]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    source = 'manual-plugin-state'
    candidates = @($PluginId)
    changed = $true
  }
  # Keep manual enable/disable changes self-contained and reversible. An
  # empty patch file is still written so callers can distinguish a deliberate
  # enable operation from a missing state root or an incomplete run.
  Write-DshGuardState -Path $statePath -State $state
  Write-DshGuardPatch -Path $patchPath -Entries (Get-DshGuardPatchEntries -State $state)
  Write-PluginStateResult -Result 'PASS' -Message $message -State $state
  exit 0
} catch {
  Write-PluginStateResult -Result 'FAIL' -Message $_.Exception.Message
  exit 1
}
