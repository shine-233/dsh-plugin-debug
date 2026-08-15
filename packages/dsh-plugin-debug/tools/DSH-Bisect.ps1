[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $scriptRoot 'DSH-Guard.psm1') -Force

function Get-DshBisectProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
    return $Object[$Name]
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Read-DshBisectJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "bisect input does not exist: $Path"
  }
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Length -gt 4MB) { throw 'bisect input is larger than 4 MiB' }
  try {
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw "bisect input is not valid JSON: $($_.Exception.Message)"
  }
}

function Get-DshBisectManifest {
  param([Parameter(Mandatory = $true)]$InputObject)
  $manifest = Get-DshBisectProperty -Object $InputObject -Name 'profileManifest'
  if ($null -eq $manifest) { $manifest = Get-DshBisectProperty -Object $InputObject -Name 'manifest' }
  if ($null -eq $manifest) {
    $hasDependencies = $null -ne (Get-DshBisectProperty -Object $InputObject -Name 'dependencies')
    if ($hasDependencies) { $manifest = $InputObject }
  }
  if ($null -eq $manifest) { throw 'bisect input must contain profileManifest or manifest' }
  return $manifest
}

function Get-DshBisectInventory {
  param([Parameter(Mandatory = $true)]$InputObject)
  $inventory = Get-DshBisectProperty -Object $InputObject -Name 'inventory'
  if ($null -eq $inventory) { $inventory = Get-DshBisectProperty -Object $InputObject -Name 'pluginInventory' }
  if ($null -ne $inventory) {
    $entries = Get-DshBisectProperty -Object $inventory -Name 'entries'
    if ($null -ne $entries) { return @($entries) }
    return @($inventory)
  }
  $entries = Get-DshBisectProperty -Object $InputObject -Name 'entries'
  return @($entries)
}

function Get-DshBisectEvidence {
  param([Parameter(Mandatory = $true)]$InputObject)
  foreach ($name in @('failureEvidence', 'failures', 'evidence')) {
    $value = Get-DshBisectProperty -Object $InputObject -Name $name
    if ($null -ne $value) { return @($value) }
  }
  $inventory = Get-DshBisectProperty -Object $InputObject -Name 'pluginInventory'
  $failed = Get-DshBisectProperty -Object $inventory -Name 'failed'
  return @($failed)
}

function Get-DshBisectIdentity {
  param([Parameter(Mandatory = $true)]$Entry)
  $moduleName = [string](Get-DshBisectProperty -Object $Entry -Name 'moduleName')
  if ([string]::IsNullOrWhiteSpace($moduleName)) { $moduleName = [string](Get-DshBisectProperty -Object $Entry -Name 'name') }
  if ([string]::IsNullOrWhiteSpace($moduleName)) { $moduleName = [string](Get-DshBisectProperty -Object $Entry -Name 'pluginId') }
  $entryId = [string](Get-DshBisectProperty -Object $Entry -Name 'entryId')
  if ([string]::IsNullOrWhiteSpace($entryId)) { $entryId = [string](Get-DshBisectProperty -Object $Entry -Name 'id') }
  return [PSCustomObject]@{
    moduleName = if ([string]::IsNullOrWhiteSpace($moduleName)) { $null } else { $moduleName }
    entryId = if ([string]::IsNullOrWhiteSpace($entryId)) { $null } else { $entryId }
  }
}

function Test-DshBisectIdentityMatch {
  param(
    [Parameter(Mandatory = $true)]$Evidence,
    [Parameter(Mandatory = $true)][string]$ModuleName,
    [Parameter(Mandatory = $true)][string]$EntryId
  )
  $evidenceModule = [string](Get-DshBisectProperty -Object $Evidence -Name 'moduleName')
  if ([string]::IsNullOrWhiteSpace($evidenceModule)) { $evidenceModule = [string](Get-DshBisectProperty -Object $Evidence -Name 'module') }
  $evidencePlugin = [string](Get-DshBisectProperty -Object $Evidence -Name 'pluginId')
  if ([string]::IsNullOrWhiteSpace($evidencePlugin)) { $evidencePlugin = [string](Get-DshBisectProperty -Object $Evidence -Name 'name') }
  $evidenceEntry = [string](Get-DshBisectProperty -Object $Evidence -Name 'entryId')
  return (-not [string]::IsNullOrWhiteSpace($ModuleName) -and $evidenceModule -ceq $ModuleName) -or
    (-not [string]::IsNullOrWhiteSpace($ModuleName) -and $evidencePlugin -ceq $ModuleName) -or
    (-not [string]::IsNullOrWhiteSpace($EntryId) -and $evidenceEntry -ceq $EntryId) -or
    (-not [string]::IsNullOrWhiteSpace($EntryId) -and $evidencePlugin -ceq $EntryId)
}

function Get-DshBisectEvidenceKinds {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Evidence,
    [Parameter(Mandatory = $true)][string]$ModuleName,
    [Parameter(Mandatory = $true)][string]$EntryId
  )
  $kinds = @()
  foreach ($item in @($Evidence)) {
    if ($null -eq $item -or -not (Test-DshBisectIdentityMatch -Evidence $item -ModuleName $ModuleName -EntryId $EntryId)) { continue }
    $kind = [string](Get-DshBisectProperty -Object $item -Name 'kind')
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = [string](Get-DshBisectProperty -Object $item -Name 'type') }
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'failure-evidence' }
    if ($kind.Length -gt 80) { $kind = $kind.Substring(0, 80) }
    $kinds += $kind
  }
  return @($kinds | Sort-Object -Unique)
}

function Get-DshBisectEvidenceDigest {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ModuleName, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EvidenceKinds)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$ModuleName|$EvidenceKinds")
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-DshBisectCandidate {
  param(
    [Parameter(Mandatory = $true)]$Entry,
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Evidence
  )
  $identity = Get-DshBisectIdentity -Entry $Entry
  $moduleName = [string]$identity.moduleName
  $entryId = [string]$identity.entryId
  $moduleKey = if (-not [string]::IsNullOrWhiteSpace($moduleName)) { $moduleName } else { $entryId }
  $fiberPhase = [string](Get-DshBisectProperty -Object $Entry -Name 'fiberPhase')
  $status = [string](Get-DshBisectProperty -Object $Entry -Name 'status')
  $enabledValue = Get-DshBisectProperty -Object $Entry -Name 'enabled'
  $enabled = if ($null -eq $enabledValue) { $true } else { [bool]$enabledValue }
  $evidenceKinds = @(Get-DshBisectEvidenceKinds -Evidence $Evidence -ModuleName $moduleName -EntryId $entryId)
  $observedFailure = ($fiberPhase -eq 'failed' -or $status -in @('failed', 'error', 'crashed')) -or $evidenceKinds.Count -gt 0
  $protectedReason = $null
  if ([string]::IsNullOrWhiteSpace($moduleKey)) {
    $protectedReason = 'missing-plugin-identity'
  } elseif ($moduleName -match '^(?i:@deepseek-ai/)' -or $entryId -match '^(?i:(include:)?@deepseek-ai/)') {
    $protectedReason = 'core-package'
  } elseif ($entryId -match '^(?i:runtime:|runtime/)' -or $moduleName -match '^(?i:runtime$|@deepseek-ai/)') {
    $protectedReason = 'runtime-entry'
  }

  $mapping = $null
  $safeCandidate = $false
  if ($null -eq $protectedReason -and -not [string]::IsNullOrWhiteSpace($moduleName)) {
    $isSafe = Test-DshGuardCandidate -ModuleName $moduleName -Manifest $Manifest
    if ($isSafe) {
      $mapping = Resolve-DshPatchEntryId -Entry ([PSCustomObject]@{ entryId = $entryId; moduleName = $moduleName }) -Manifest $Manifest
      if ($mapping.resolved) { $safeCandidate = $true }
    }
    if (-not $safeCandidate) {
      $dependencySpec = Get-DshManifestPackageSpec -Manifest $Manifest -Name $moduleName
      if ($null -ne $dependencySpec) { $protectedReason = 'non-plugin-dependency' }
      else { $protectedReason = 'unmapped-or-unknown' }
    }
  }

  $classification = if ($safeCandidate) { 'safe' } elseif ($protectedReason -in @('core-package', 'runtime-entry', 'non-plugin-dependency')) { 'protected' } else { 'ambiguous' }
  $riskScore = 0
  if ($safeCandidate) { $riskScore += 10 }
  if ($observedFailure) { $riskScore += 20 }
  if ($fiberPhase -eq 'failed' -or $status -in @('failed', 'error', 'crashed')) { $riskScore += 10 }
  return [PSCustomObject]([ordered]@{
    pluginId = if ($null -ne $mapping -and $mapping.resolved) { [string]$mapping.patchEntryId } elseif (-not [string]::IsNullOrWhiteSpace($moduleName)) { $moduleName } else { $entryId }
    inventoryEntryId = if ([string]::IsNullOrWhiteSpace($entryId)) { $null } else { $entryId }
    moduleName = if ([string]::IsNullOrWhiteSpace($moduleName)) { $null } else { $moduleName }
    classification = $classification
    reason = if ($safeCandidate) { 'manifest-mapped-safe-third-party-plugin' } else { $protectedReason }
    mapping = if ($null -ne $mapping) { [string]$mapping.mapping } else { 'unresolved' }
    observedFailure = $observedFailure
    enabled = $enabled
    evidenceKinds = @($evidenceKinds)
    evidenceDigest = Get-DshBisectEvidenceDigest -ModuleName $moduleKey -EvidenceKinds (($evidenceKinds -join ','))
    humanApprovalRequired = $true
    automaticAction = 'none'
    riskScore = $riskScore
  })
}

function New-DshBisectStep {
  param(
    [Parameter(Mandatory = $true)][int]$Number,
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][string]$Expected,
    [string]$PluginId = ''
  )
  return [ordered]@{
    step = $Number
    phase = $Phase
    pluginId = if ([string]::IsNullOrWhiteSpace($PluginId)) { $null } else { $PluginId }
    action = $Action
    expected = $Expected
    humanApprovalRequired = $true
    executesCommand = $false
    changesProfile = $false
    changesWorkspace = $false
  }
}

try {
  $inputObject = Read-DshBisectJson -Path $InputPath
  $manifest = Get-DshBisectManifest -InputObject $inputObject
  $inventory = @(Get-DshBisectInventory -InputObject $inputObject)
  $evidence = @(Get-DshBisectEvidence -InputObject $inputObject)
  $dependencies = @(Get-DshManifestDependencyNames -Manifest $manifest)
  $candidates = @()
  $seen = @{}
  foreach ($entry in @($inventory)) {
    if ($null -eq $entry) { continue }
    $candidate = New-DshBisectCandidate -Entry $entry -Manifest $manifest -Evidence $evidence
    $key = if (-not [string]::IsNullOrWhiteSpace([string]$candidate.moduleName)) { [string]$candidate.moduleName } else { [string]$candidate.inventoryEntryId }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = "missing-$($candidates.Count)" }
    if ($seen.ContainsKey($key)) {
      $candidate.classification = 'ambiguous'
      $candidate.reason = 'duplicate-plugin-identity'
      $candidate.mapping = 'ambiguous'
      $candidate.automaticAction = 'none'
      $candidate.humanApprovalRequired = $true
      $candidate.riskScore = 0
    } else {
      $seen[$key] = $true
    }
    $candidates += $candidate
  }

  $safe = @($candidates | Where-Object { $_.classification -eq 'safe' } | Sort-Object @{ Expression = { [int]$_.riskScore }; Descending = $true }, pluginId)
  $ambiguous = @($candidates | Where-Object { $_.classification -eq 'ambiguous' } | Sort-Object pluginId)
  $protected = @($candidates | Where-Object { $_.classification -eq 'protected' } | Sort-Object pluginId)
  $steps = [System.Collections.Generic.List[object]]::new()
  [void]$steps.Add((New-DshBisectStep -Number 1 -Phase 'baseline' -Action 'Capture a metadata-only baseline for the same reproducible failure without changing Profile or workspace; pin the input evidenceDigest.' -Expected 'The baseline must be repeatable; stop and switch to manual investigation if it is not.'))
  $stepNumber = 2
  foreach ($candidate in $safe) {
    [void]$steps.Add((New-DshBisectStep -Number $stepNumber -Phase 'candidate-test' -PluginId ([string]$candidate.pluginId) -Action 'Have a human change only this plugin load state in an isolated Profile, reproduce the same failure, and collect metadata-only evidence; this plan does not perform that change.' -Expected 'Mark implicated when the failure disappears, or not-implicated when it remains, then continue.'))
    $stepNumber++
  }
  [void]$steps.Add((New-DshBisectStep -Number $stepNumber -Phase 'review' -Action 'Compare each metadata-only evidenceDigest and do not turn correlation into a root-cause claim; conflicts, duplicates, and core packages require manual review.' -Expected 'Record implicated, not-implicated, or INCONCLUSIVE while leaving the original Profile unchanged.'))

  $result = if ($safe.Count -gt 0) { 'PASS' } elseif ($ambiguous.Count -gt 0) { 'WARN' } else { 'INCONCLUSIVE' }
  $report = [ordered]@{
    kind = 'dsh-plugin-bisect-plan'
    schemaVersion = 1
    result = $result
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    offline = $true
    networkAccessed = $false
    readOnly = $true
    inputSummary = [ordered]@{
      inventoryCount = $inventory.Count
      evidenceCount = $evidence.Count
      manifestDependencyCount = $dependencies.Count
      rawInputStored = $false
      pathsStored = $false
    }
    candidates = @($safe + $ambiguous + $protected)
    steps = @($steps)
    safety = [ordered]@{
      automaticAction = 'none'
      autoDisabled = $false
      profileChanged = $false
      workspaceChanged = $false
      commandsExecuted = $false
      corePackagesProtected = $true
      unresolvedMappingsRequireManualReview = $true
      humanApprovalRequired = $true
    }
    privacy = [ordered]@{
      metadataOnly = $true
      rawToolArgumentsStored = $false
      rawToolResultsStored = $false
      rawFailureMessagesStored = $false
      credentialsStored = $false
      networkPayloadSent = $false
    }
  }
  $json = $report | ConvertTo-Json -Depth 30
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
  }
  $json
  exit 0
} catch {
  [ordered]@{
    kind = 'dsh-plugin-bisect-plan'
    schemaVersion = 1
    result = 'FAIL'
    offline = $true
    networkAccessed = $false
    readOnly = $true
    error = $_.Exception.Message
    errorLine = [int]$_.InvocationInfo.ScriptLineNumber
    errorCommand = [string]$_.InvocationInfo.MyCommand.Name
    safety = [ordered]@{
      automaticAction = 'none'
      profileChanged = $false
      workspaceChanged = $false
      commandsExecuted = $false
    }
  } | ConvertTo-Json -Depth 12
  exit 1
}
