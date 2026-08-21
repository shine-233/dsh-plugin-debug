[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'DSH-PowerShell.ps1')
$scriptPath = Join-Path $root 'Set-DSHPluginState.ps1'
$modulePath = Join-Path $root 'DSH-Guard.psm1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-plugin-state-' + [guid]::NewGuid().ToString('N'))
$dshHome = Join-Path $fixtureRoot 'home'
$stateRoot = Join-Path $fixtureRoot 'state'
$profile = 'state-fixture'
$profileRoot = Join-Path $dshHome "profiles\$profile"

function Assert-PluginState {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Invoke-PluginStateChild {
  param([string[]]$Arguments)
  $powershell = Get-DshPowerShellPath
  $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments
  return [PSCustomObject]@{ exitCode = $LASTEXITCODE; value = (($output -join "`n") | ConvertFrom-Json) }
}

try {
  New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
  $manifest = [PSCustomObject]@{
    name = $profile
    dependencies = [PSCustomObject]@{
      'dsh-plugin-fixture' = 'link:C:/fixture/plugin'
      '@deepseek-ai/dsh-web-app' = '0.1.1-rc.2'
    }
  }
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $profileRoot 'package.json') -Encoding UTF8

  $disabled = Invoke-PluginStateChild -Arguments @(
    '-DesiredState', 'disable', '-PluginId', 'dsh-plugin-fixture', '-Profile', $profile,
    '-DshHome', $dshHome, '-StateRoot', $stateRoot
  )
  Assert-PluginState ($disabled.exitCode -eq 0 -and $disabled.value.result -eq 'PASS') 'disable should succeed'
  $patchPath = Join-Path $stateRoot 'guard.patch.yml'
  $patch = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
  Assert-PluginState ($patch -match "(?m)^- id: 'dsh-plugin-fixture'\r?$") 'manual disable should use Profile id'
  Assert-PluginState ($patch -match '(?m)^  disabled: true\r?$') 'manual disable should write disabled true'

  $enabled = Invoke-PluginStateChild -Arguments @(
    '-DesiredState', 'enable', '-PluginId', 'dsh-plugin-fixture', '-Profile', $profile,
    '-DshHome', $dshHome, '-StateRoot', $stateRoot
  )
  Assert-PluginState ($enabled.exitCode -eq 0 -and $enabled.value.result -eq 'PASS') 'enable should succeed'
  $patch = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
  Assert-PluginState ($patch -notmatch "(?m)^- id: 'dsh-plugin-fixture'\r?$") 'enable should remove manual patch entry'

  Import-Module $modulePath -Force
  $statePath = Join-Path $stateRoot 'guard-state.json'
  $state = New-DshGuardState -Profile $profile
  Add-DshGuardQuarantine -State $state -Candidate ([PSCustomObject]@{
    entryId = 'dsh-plugin-fixture'; inventoryEntryId = 'include:dsh-plugin-fixture'; patchEntryId = 'dsh-plugin-fixture'
    moduleName = 'dsh-plugin-fixture'; reason = 'host-plugin-inventory:fiber-failed'; attribution = 'observed'; mapping = 'stripped-include'
  }) | Out-Null
  Write-DshGuardState -Path $statePath -State $state
  Write-DshGuardPatch -Path $patchPath -Entries (Get-DshGuardPatchEntries -State $state)
  $blocked = Invoke-PluginStateChild -Arguments @(
    '-DesiredState', 'enable', '-PluginId', 'dsh-plugin-fixture', '-Profile', $profile,
    '-DshHome', $dshHome, '-StateRoot', $stateRoot
  )
  Assert-PluginState ($blocked.exitCode -ne 0 -and $blocked.value.result -eq 'FAIL') 'crash quarantine should require explicit clear'
  $cleared = Invoke-PluginStateChild -Arguments @(
    '-DesiredState', 'enable', '-ClearQuarantine', '-PluginId', 'dsh-plugin-fixture', '-Profile', $profile,
    '-DshHome', $dshHome, '-StateRoot', $stateRoot
  )
  Assert-PluginState ($cleared.exitCode -eq 0 -and $cleared.value.result -eq 'PASS') 'explicit clear should enable a quarantined plugin'

  [PSCustomObject]@{ result = 'PASS'; manualDisable = $true; crashClearRequiresFlag = $true }
} finally {
  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}
