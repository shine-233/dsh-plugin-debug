[CmdletBinding()]
param(
  [switch]$SkipApi,
  [string]$ApiUrl = 'http://127.0.0.1:3081/'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'DSH-Guard.psm1'
Import-Module $modulePath -Force

function Assert-Guard {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("dsh-guard-fixture-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

try {
  $manifestPath = Join-Path $fixtureRoot 'package.json'
  $statePath = Join-Path $fixtureRoot 'guard-state.json'
  $patchPath = Join-Path $fixtureRoot 'guard.patch.yml'
  $manifestObject = [PSCustomObject]@{
    name = 'dsh-profile-fixture'
    dependencies = [PSCustomObject]@{
      'dsh-plugin-debug' = 'link:C:/fixture/dsh-plugin-debug'
      '@deepseek-ai/dsh-web-app' = '0.1.0-rc.6'
      'other-plugin' = '2.0.0'
      'ordinary-library' = '1.2.3'
    }
  }
  $manifestObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  $manifest = Read-DshProfileManifest -Path $manifestPath

  Assert-Guard (Test-DshGuardCandidate -ModuleName 'dsh-plugin-debug' -Manifest $manifest) 'local plugin should be a guard candidate'
  Assert-Guard (-not (Test-DshGuardCandidate -ModuleName '@deepseek-ai/dsh-web-app' -Manifest $manifest)) 'core web bundle must be protected'
  Assert-Guard (-not (Test-DshGuardCandidate -ModuleName 'ordinary-library' -Manifest $manifest)) 'ordinary dependency must not be quarantined'

  $inventory = @(
    [PSCustomObject]@{ entryId = 'include:dsh-plugin-debug'; moduleName = 'dsh-plugin-debug'; fiberPhase = 'failed'; enabled = $true }
    [PSCustomObject]@{ entryId = 'web-app'; moduleName = '@deepseek-ai/dsh-web-app'; fiberPhase = 'failed'; enabled = $true }
  )
  $candidates = @(Get-DshGuardCandidates -Entries $inventory -Manifest $manifest)
  Assert-Guard ($candidates.Count -eq 1) 'inventory should produce one safe candidate'
  Assert-Guard ($candidates[0].entryId -eq 'dsh-plugin-debug') 'candidate entry id should match the Profile patch row id'
  Assert-Guard ($candidates[0].inventoryEntryId -eq 'include:dsh-plugin-debug') 'candidate must retain the raw inventory entry id'
  Assert-Guard ($candidates[0].mapping -eq 'stripped-include') 'include inventory id must map explicitly by stripping the loader wrapper'

  $unresolved = @(
    [PSCustomObject]@{ entryId = 'include:unknown-row'; moduleName = 'dsh-plugin-debug'; fiberPhase = 'failed'; enabled = $true }
  )
  $unresolvedCandidates = @(Get-DshGuardCandidates -Entries $unresolved -Manifest $manifest)
  Assert-Guard ($unresolvedCandidates.Count -eq 1) 'module-name fallback should resolve a unique Profile dependency'
  Assert-Guard ($unresolvedCandidates[0].mapping -eq 'module-name') 'module-name fallback must be recorded'

  $ambiguousManifest = [PSCustomObject]@{
    dependencies = [PSCustomObject]@{
      'dsh-plugin-one' = 'link:C:/fixture/one'
      'dsh-plugin-two' = 'link:C:/fixture/two'
    }
  }
  $ambiguousResolution = Resolve-DshPatchEntryId -Entry ([PSCustomObject]@{
      entryId = 'include:unknown-row'
      moduleName = 'not-a-dependency'
    }) -Manifest $ambiguousManifest
  Assert-Guard (-not $ambiguousResolution.resolved) 'unresolved inventory rows must not be guessed'

  $state = New-DshGuardState -Profile 'fixture'
  Add-DshGuardFailure -State $state -Candidate $candidates[0] | Out-Null
  Add-DshGuardQuarantine -State $state -Candidate $candidates[0] | Out-Null
  Write-DshGuardState -Path $statePath -State $state
  $roundTrip = Read-DshGuardState -Path $statePath -Profile 'fixture'
  Assert-Guard (@($roundTrip.failures).Count -eq 1) 'failure state must round-trip'
  Assert-Guard (@($roundTrip.quarantined).Count -eq 1) 'quarantine state must round-trip'

  Write-DshGuardPatch -Path $patchPath -Entries (Get-DshGuardPatchEntries -State $roundTrip)
  $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
  Assert-Guard ($patchText -match "(?m)^- id: 'dsh-plugin-debug'\r?$") 'patch must target the real plugin row id'
  Assert-Guard ($patchText -match '(?m)^  disabled: true\r?$') 'patch must disable the row'
  Assert-Guard ($patchText -notmatch 'include:') 'patch must not invent an include row id'

  $startupMatches = @(Get-DshStartupGuardCandidates -Manifest $manifest -ErrorText 'Error while loading dsh-plugin-debug')
  Assert-Guard ($startupMatches.Count -eq 1) 'startup log name matching should identify the plugin'
  $singleFallback = Get-DshSingleStartupGuardCandidate -Manifest $manifest -ErrorText 'fatal plugin startup failure'
  Assert-Guard ($null -eq $singleFallback) 'single-candidate fallback must not apply when the fixture has multiple dependencies'

  $remoteApiError = $null
  try {
    Invoke-DshGuardApi -BaseUrl 'https://example.com/' -Method 'session.history' -Arguments @{ sessionId = 'fixture' } -TimeoutSec 1 | Out-Null
  } catch {
    $remoteApiError = $_.Exception.Message
  }
  Assert-Guard ($remoteApiError -match 'not loopback|DSH_DEBUG_API_ALLOWED_HOSTS') 'remote API BaseUrl must be rejected before any request'

  $credentialUrlError = $null
  try {
    Invoke-DshGuardApi -BaseUrl 'http://user:password@127.0.0.1:3081/' -Method 'session.history' -Arguments @{} -TimeoutSec 1 | Out-Null
  } catch {
    $credentialUrlError = $_.Exception.Message
  }
  Assert-Guard ($credentialUrlError -match 'userinfo|credentials') 'API BaseUrl must reject embedded credentials'

  $apiStatus = 'skipped'
  if (-not $SkipApi) {
    try {
      $entries = @(Get-DshPluginInventory -BaseUrl $ApiUrl -TimeoutSec 3)
      Assert-Guard ($null -ne $entries) 'inventory API should return an array'
      $apiStatus = "ok ($($entries.Count) entries)"
    } catch {
      $apiStatus = "unavailable ($($_.Exception.Message))"
    }
  }

  [PSCustomObject]@{
    result = 'PASS'
    candidate = $candidates[0].moduleName
    patch = $patchPath
    api = $apiStatus
    remoteBaseUrlRejected = $true
    credentialBaseUrlRejected = $true
  }
} finally {
  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}
