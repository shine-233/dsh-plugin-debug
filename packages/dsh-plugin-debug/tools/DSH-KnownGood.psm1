Set-StrictMode -Version Latest

$script:KnownGoodSchemaVersion = 1
$script:KnownGoodMaxAutomaticRestores = 1

function Get-DshKnownGoodProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Set-DshKnownGoodProperty {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()]$Value
  )
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force
  } else {
    $property.Value = $Value
  }
}

function Test-DshKnownGoodPathWithin {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$CandidatePath
  )
  $base = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $candidate = [IO.Path]::GetFullPath($CandidatePath)
  return $candidate.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-DshKnownGoodRegularFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $item.PSIsContainer -eq $false -and
      (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
  } catch {
    return $false
  }
}

function Get-DshKnownGoodHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-DshKnownGoodRegularFile -Path $Path)) { return $null }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Write-DshKnownGoodJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

function Resolve-DshKnownGoodPaths {
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$DshHome = '',
    [string]$CheckpointRoot = '',
    [string]$StateRoot = '',
    [string]$GuardStatePath = '',
    [string]$GuardPatchPath = ''
  )
  if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "invalid Profile: $Profile" }
  if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  }
  $resolvedHome = [IO.Path]::GetFullPath($DshHome)
  $profileRoot = [IO.Path]::GetFullPath((Join-Path $resolvedHome "profiles\$Profile"))
  if ([string]::IsNullOrWhiteSpace($CheckpointRoot)) {
    $CheckpointRoot = Join-Path $resolvedHome "recovery\known-good\$Profile"
  }
  $resolvedCheckpointRoot = [IO.Path]::GetFullPath($CheckpointRoot)
  if (Test-DshKnownGoodPathWithin -BasePath $profileRoot -CandidatePath $resolvedCheckpointRoot) {
    throw "known-good checkpoint root must be outside the Profile: $resolvedCheckpointRoot"
  }
  $resolvedStateRoot = if ([string]::IsNullOrWhiteSpace($StateRoot)) { $null } else { [IO.Path]::GetFullPath($StateRoot) }
  $resolvedGuardState = if ([string]::IsNullOrWhiteSpace($GuardStatePath)) {
    if ($null -eq $resolvedStateRoot) { $null } else { Join-Path $resolvedStateRoot 'guard-state.json' }
  } else { [IO.Path]::GetFullPath($GuardStatePath) }
  $resolvedGuardPatch = if ([string]::IsNullOrWhiteSpace($GuardPatchPath)) {
    if ($null -eq $resolvedStateRoot) { $null } else { Join-Path $resolvedStateRoot 'guard.patch.yml' }
  } else { [IO.Path]::GetFullPath($GuardPatchPath) }
  return [PSCustomObject]@{
    dshHome = $resolvedHome
    profile = $Profile
    profileRoot = $profileRoot
    checkpointRoot = $resolvedCheckpointRoot
    stateRoot = $resolvedStateRoot
    guardStatePath = $resolvedGuardState
    guardPatchPath = $resolvedGuardPatch
  }
}

function Get-DshKnownGoodProfileDefinitions {
  param([Parameter(Mandatory = $true)][string]$Profile)
  return @(
    [PSCustomObject]@{ key = "profiles\$Profile\package.json"; relativePath = "profiles\$Profile\package.json"; role = 'profile' }
    [PSCustomObject]@{ key = "profiles\$Profile\cordis.yml"; relativePath = "profiles\$Profile\cordis.yml"; role = 'profile' }
    [PSCustomObject]@{ key = "profiles\$Profile\cordis.patch.yml"; relativePath = "profiles\$Profile\cordis.patch.yml"; role = 'profile' }
    [PSCustomObject]@{ key = "profiles\$Profile\pnpm-workspace.yaml"; relativePath = "profiles\$Profile\pnpm-workspace.yaml"; role = 'profile' }
    [PSCustomObject]@{ key = 'settings.yaml'; relativePath = 'settings.yaml'; role = 'profile' }
  )
}

function Get-DshKnownGoodCheckpointPath {
  param(
    [Parameter(Mandatory = $true)][string]$CheckpointRoot,
    [Parameter(Mandatory = $true)][string]$CheckpointId
  )
  if ($CheckpointId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') { throw "invalid checkpoint id: $CheckpointId" }
  $root = [IO.Path]::GetFullPath($CheckpointRoot)
  $path = [IO.Path]::GetFullPath((Join-Path $root $CheckpointId))
  if (-not (Test-DshKnownGoodPathWithin -BasePath $root -CandidatePath $path)) { throw 'checkpoint escaped its root' }
  return $path
}

function Read-DshKnownGoodManifest {
  param(
    [Parameter(Mandatory = $true)][string]$CheckpointRoot,
    [Parameter(Mandatory = $true)][string]$CheckpointId
  )
  $checkpointPath = Get-DshKnownGoodCheckpointPath -CheckpointRoot $CheckpointRoot -CheckpointId $CheckpointId
  $manifestPath = Join-Path $checkpointPath 'manifest.json'
  if (-not (Test-DshKnownGoodRegularFile -Path $manifestPath)) { throw "known-good manifest does not exist: $manifestPath" }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([int]$manifest.schemaVersion -ne $script:KnownGoodSchemaVersion) { throw "unsupported known-good schema: $($manifest.schemaVersion)" }
  return $manifest
}

function Get-DshKnownGoodRecord {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Role
  )
  $exists = Test-DshKnownGoodRegularFile -Path $SourcePath
  $record = [ordered]@{
    key = $Key
    role = $Role
    exists = $exists
    bytes = $null
    sha256 = $null
  }
  if ($exists) {
    $parent = Split-Path -Parent $PayloadPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $SourcePath -Destination $PayloadPath -Force
    $item = Get-Item -LiteralPath $SourcePath -Force
    $record.bytes = [int64]$item.Length
    $record.sha256 = Get-DshKnownGoodHash -Path $SourcePath
  }
  return [PSCustomObject]$record
}

function Get-DshKnownGoodGuardState {
  param([AllowNull()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-DshKnownGoodRegularFile -Path $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-DshKnownGoodQuarantineEntries {
  param([AllowNull()]$State)
  if ($null -eq $State) { return @() }
  $entries = Get-DshKnownGoodProperty -Object $State -Name 'quarantined'
  return @($entries | ForEach-Object {
    [PSCustomObject]@{
      entryId = [string](Get-DshKnownGoodProperty -Object $_ -Name 'entryId')
      patchEntryId = [string](Get-DshKnownGoodProperty -Object $_ -Name 'patchEntryId')
      moduleName = [string](Get-DshKnownGoodProperty -Object $_ -Name 'moduleName')
      reason = [string](Get-DshKnownGoodProperty -Object $_ -Name 'reason')
      attribution = [string](Get-DshKnownGoodProperty -Object $_ -Name 'attribution')
      mapping = [string](Get-DshKnownGoodProperty -Object $_ -Name 'mapping')
      quarantinedAt = [string](Get-DshKnownGoodProperty -Object $_ -Name 'quarantinedAt')
    }
  } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.entryId) -or -not [string]::IsNullOrWhiteSpace($_.moduleName) })
}

function Merge-DshKnownGoodQuarantine {
  param(
    [AllowNull()]$CheckpointState,
    [AllowNull()]$CurrentState
  )
  $merged = [System.Collections.Generic.List[object]]::new()
  foreach ($entry in @(Get-DshKnownGoodQuarantineEntries -State $CheckpointState) + @(Get-DshKnownGoodQuarantineEntries -State $CurrentState)) {
    $key = if (-not [string]::IsNullOrWhiteSpace($entry.entryId)) { $entry.entryId } else { $entry.moduleName }
    if (@($merged | Where-Object {
      $otherKey = if (-not [string]::IsNullOrWhiteSpace($_.entryId)) { $_.entryId } else { $_.moduleName }
      $otherKey -ceq $key
    }).Count -eq 0) { [void]$merged.Add($entry) }
  }
  return @($merged)
}

function Write-DshKnownGoodGuardPatch {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowEmptyCollection()][object[]]$Entries = @()
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $lines = @(
    '# Generated by dsh-plugin-debug known-good recovery.'
    '# Failed/quarantined entries remain disabled after a checkpoint restore.'
  )
  $count = 0
  foreach ($entry in @($Entries | Sort-Object entryId, moduleName -Unique)) {
    $entryId = [string]$entry.entryId
    if ([string]::IsNullOrWhiteSpace($entryId)) { continue }
    $safeId = $entryId.Replace("'", "''")
    $lines += "- id: '$safeId'"
    if (-not [string]::IsNullOrWhiteSpace([string]$entry.moduleName)) {
      $lines += "  name: '$($entry.moduleName.Replace("'", "''"))'"
    }
    $lines += '  disabled: true'
    $count += 1
  }
  if ($count -eq 0) { $lines += '[]' }
  [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Save-DshKnownGoodCheckpoint {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$DshHome = '',
    [string]$CheckpointRoot = '',
    [string]$StateRoot = '',
    [string]$GuardStatePath = '',
    [string]$GuardPatchPath = '',
    [string]$DshVersion = '',
    [string]$Label = 'healthy',
    [int]$MaxAutomaticRestores = 1
  )
  if ($MaxAutomaticRestores -lt 0 -or $MaxAutomaticRestores -gt 1) { throw 'MaxAutomaticRestores must be 0 or 1' }
  $paths = Resolve-DshKnownGoodPaths -Profile $Profile -DshHome $DshHome -CheckpointRoot $CheckpointRoot -StateRoot $StateRoot -GuardStatePath $GuardStatePath -GuardPatchPath $GuardPatchPath
  if (-not (Test-Path -LiteralPath $paths.dshHome -PathType Container)) { throw "DSH_HOME does not exist: $($paths.dshHome)" }
  if (-not (Test-Path -LiteralPath $paths.profileRoot -PathType Container)) { throw "Profile does not exist: $($paths.profileRoot)" }
  $id = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $checkpointPath = Get-DshKnownGoodCheckpointPath -CheckpointRoot $paths.checkpointRoot -CheckpointId $id
  $payloadRoot = Join-Path $checkpointPath 'payload'
  New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
  $records = [System.Collections.Generic.List[object]]::new()
  try {
    foreach ($definition in @(Get-DshKnownGoodProfileDefinitions -Profile $Profile)) {
      $source = Join-Path $paths.dshHome $definition.relativePath
      $payload = Join-Path $payloadRoot ('profile\' + $definition.relativePath)
      [void]$records.Add((Get-DshKnownGoodRecord -SourcePath $source -PayloadPath $payload -Key $definition.key -Role $definition.role))
    }
    if ($null -ne $paths.guardStatePath) {
      [void]$records.Add((Get-DshKnownGoodRecord -SourcePath $paths.guardStatePath -PayloadPath (Join-Path $payloadRoot 'guard\guard-state.json') -Key 'guard-state.json' -Role 'guard-state'))
    }
    if ($null -ne $paths.guardPatchPath) {
      [void]$records.Add((Get-DshKnownGoodRecord -SourcePath $paths.guardPatchPath -PayloadPath (Join-Path $payloadRoot 'guard\guard.patch.yml') -Key 'guard.patch.yml' -Role 'guard-patch'))
    }
    $guardState = Get-DshKnownGoodGuardState -Path $paths.guardStatePath
    $manifest = [ordered]@{
      schemaVersion = $script:KnownGoodSchemaVersion
      kind = 'dsh-known-good'
      id = $id
      profile = $Profile
      createdAt = (Get-Date).ToUniversalTime().ToString('o')
      label = $Label
      dshVersion = if ([string]::IsNullOrWhiteSpace($DshVersion)) { 'unknown' } else { $DshVersion }
      automaticRestoreCount = 0
      maxAutomaticRestores = $MaxAutomaticRestores
      status = 'healthy'
      dshHomeObserved = $paths.dshHome
      files = @($records)
      quarantineAtSave = @(Get-DshKnownGoodQuarantineEntries -State $guardState)
      safety = [ordered]@{
        workspaceCaptured = $false
        workspaceRestored = $false
        envCaptured = $false
        failedQuarantinePreserved = $true
        automaticRestoreBounded = $true
      }
    }
    Write-DshKnownGoodJson -Path (Join-Path $checkpointPath 'manifest.json') -Value $manifest
    return [PSCustomObject]@{
      result = 'PASS'
      status = 'healthy'
      checkpointId = $id
      checkpointPath = $checkpointPath
      profile = $Profile
      dshVersion = $manifest.dshVersion
      files = @($records | Where-Object { $_.exists } | ForEach-Object { $_.key })
      quarantineCount = @($manifest.quarantineAtSave).Count
      workspaceCaptured = $false
      maxAutomaticRestores = $MaxAutomaticRestores
    }
  } catch {
    if (Test-Path -LiteralPath $checkpointPath -PathType Container) { Remove-Item -LiteralPath $checkpointPath -Recurse -Force -ErrorAction SilentlyContinue }
    throw
  }
}

function Get-DshKnownGoodCheckpoints {
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$DshHome = '',
    [string]$CheckpointRoot = '',
    [string]$StateRoot = '',
    [string]$GuardStatePath = '',
    [string]$GuardPatchPath = ''
  )
  $paths = Resolve-DshKnownGoodPaths -Profile $Profile -DshHome $DshHome -CheckpointRoot $CheckpointRoot -StateRoot $StateRoot -GuardStatePath $GuardStatePath -GuardPatchPath $GuardPatchPath
  if (-not (Test-Path -LiteralPath $paths.checkpointRoot -PathType Container)) { return @() }
  $items = @()
  foreach ($directory in @(Get-ChildItem -LiteralPath $paths.checkpointRoot -Directory -Force | Sort-Object Name -Descending)) {
    try {
      $manifest = Read-DshKnownGoodManifest -CheckpointRoot $paths.checkpointRoot -CheckpointId $directory.Name
      $items += [PSCustomObject]@{
        checkpointId = [string]$manifest.id
        profile = [string]$manifest.profile
        createdAt = [string]$manifest.createdAt
        label = [string]$manifest.label
        status = [string]$manifest.status
        automaticRestoreCount = [int]$manifest.automaticRestoreCount
        maxAutomaticRestores = [int]$manifest.maxAutomaticRestores
        path = $directory.FullName
      }
    } catch {
      $items += [PSCustomObject]@{ checkpointId = $directory.Name; path = $directory.FullName; status = 'unreadable' }
    }
  }
  return @($items)
}

function Test-DshKnownGoodWeb {
  param(
    [string]$BaseUrl = '',
    [string]$FailedPluginId = ''
  )
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    return [PSCustomObject]@{ status = 'not-requested'; ready = $true; inventory = 'not-requested'; failedEntries = @(); note = 'No BaseUrl was supplied; Web readiness was not checked.' }
  }
  try {
    $response = Invoke-WebRequest -Uri $BaseUrl -Method Get -UseBasicParsing -TimeoutSec 5
    $ready = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
    $failedEntries = @()
    $inventoryStatus = 'not-requested'
    try {
      $body = @{ type = 'client-request'; rpcId = [guid]::NewGuid().ToString('N'); method = 'pluginInventory/list'; payload = @{ args = @{} } } | ConvertTo-Json -Depth 10 -Compress
      $inventoryResponse = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/api/pluginInventory/list') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5
      $value = Get-DshKnownGoodProperty -Object (Get-DshKnownGoodProperty -Object $inventoryResponse -Name 'result') -Name 'value'
      $entries = @(Get-DshKnownGoodProperty -Object $value -Name 'entries')
      $failedEntries = @($entries | Where-Object {
        $phase = [string](Get-DshKnownGoodProperty -Object $_ -Name 'fiberPhase')
        $enabledProperty = Get-DshKnownGoodProperty -Object $_ -Name 'enabled'
        $phase -eq 'failed' -and $enabledProperty -ne $false
      } | ForEach-Object {
        [ordered]@{ entryId = [string](Get-DshKnownGoodProperty -Object $_ -Name 'entryId'); moduleName = [string](Get-DshKnownGoodProperty -Object $_ -Name 'moduleName') }
      })
      $inventoryStatus = if ($failedEntries.Count -eq 0) { 'healthy' } else { 'failed-entries' }
    } catch {
      $inventoryStatus = 'unavailable'
    }
    $webStatus = 'degraded'
    if ($ready -and $inventoryStatus -in @('healthy', 'not-requested')) { $webStatus = 'ready' }
    $failedPluginDisabled = $true
    if (-not [string]::IsNullOrWhiteSpace($FailedPluginId)) {
      $failedPluginDisabled = @($failedEntries | Where-Object { $_.entryId -eq $FailedPluginId -or $_.moduleName -eq $FailedPluginId }).Count -eq 0
    }
    return [PSCustomObject]@{
      status = $webStatus
      ready = $ready
      httpStatus = [int]$response.StatusCode
      inventory = $inventoryStatus
      failedEntries = $failedEntries
      failedPluginDisabled = $failedPluginDisabled
      note = 'Readiness is a loopback HTTP observation; it is not proof of model or Tool Call success.'
    }
  } catch {
    return [PSCustomObject]@{ status = 'unavailable'; ready = $false; inventory = 'unavailable'; failedEntries = @(); failedPluginDisabled = $false; error = 'loopback Web readiness request failed' }
  }
}

function Restore-DshKnownGoodCheckpoint {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$CheckpointId,
    [string]$DshHome = '',
    [string]$CheckpointRoot = '',
    [string]$StateRoot = '',
    [string]$GuardStatePath = '',
    [string]$GuardPatchPath = '',
    [string]$BaseUrl = '',
    [string]$FailedPluginId = '',
    [switch]$Automatic,
    [switch]$Force
  )
  $paths = Resolve-DshKnownGoodPaths -Profile $Profile -DshHome $DshHome -CheckpointRoot $CheckpointRoot -StateRoot $StateRoot -GuardStatePath $GuardStatePath -GuardPatchPath $GuardPatchPath
  $manifest = Read-DshKnownGoodManifest -CheckpointRoot $paths.checkpointRoot -CheckpointId $CheckpointId
  if ([string]$manifest.profile -cne $Profile) { throw "checkpoint belongs to profile '$($manifest.profile)', not '$Profile'" }
  $restoreCount = [int](Get-DshKnownGoodProperty -Object $manifest -Name 'automaticRestoreCount')
  $maxAutomatic = [int](Get-DshKnownGoodProperty -Object $manifest -Name 'maxAutomaticRestores')
  if ($Automatic -and $restoreCount -ge $maxAutomatic) { throw "AUTO_RESTORE_LIMIT: checkpoint $CheckpointId has already used its bounded automatic restore" }
  $checkpointPath = Get-DshKnownGoodCheckpointPath -CheckpointRoot $paths.checkpointRoot -CheckpointId $CheckpointId
  $records = @($manifest.files | Where-Object { [string]$_.role -eq 'profile' })
  $conflicts = [System.Collections.Generic.List[string]]::new()
  foreach ($record in $records) {
    $target = Join-Path $paths.dshHome ([string]$record.key)
    $currentExists = Test-DshKnownGoodRegularFile -Path $target
    $currentHash = if ($currentExists) { Get-DshKnownGoodHash -Path $target } else { $null }
    if ([bool]$record.exists -ne $currentExists -or ([bool]$record.exists -and $currentHash -cne [string]$record.sha256)) {
      [void]$conflicts.Add([string]$record.key)
    }
  }
  if ($conflicts.Count -gt 0 -and -not $Force) {
    Set-DshKnownGoodProperty -Object $manifest -Name 'status' -Value 'MANUAL_REVIEW'
    Set-DshKnownGoodProperty -Object $manifest -Name 'lastError' -Value 'current Profile files differ from the checkpoint; restore was refused without -Force'
    Write-DshKnownGoodJson -Path (Join-Path $checkpointPath 'manifest.json') -Value $manifest
    return [PSCustomObject]@{ result = 'CONFLICT'; status = 'MANUAL_REVIEW'; checkpointId = $CheckpointId; conflicts = @($conflicts); restored = @(); failedPluginPreserved = $false; web = [PSCustomObject]@{ status = 'not-requested' } }
  }
  $currentGuardState = Get-DshKnownGoodGuardState -Path $paths.guardStatePath
  $checkpointGuardState = Get-DshKnownGoodGuardState -Path (Join-Path $checkpointPath 'payload\guard\guard-state.json')
  $mergedQuarantine = @(Merge-DshKnownGoodQuarantine -CheckpointState $checkpointGuardState -CurrentState $currentGuardState)
  $restored = [System.Collections.Generic.List[object]]::new()
  foreach ($record in $records) {
    if (-not [bool]$record.exists) { continue }
    $source = Join-Path $checkpointPath ('payload\profile\' + [string]$record.key)
    $target = Join-Path $paths.dshHome ([string]$record.key)
    if (-not (Test-DshKnownGoodRegularFile -Path $source)) { throw "checkpoint payload is missing: $source" }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $target -Force
    [void]$restored.Add([PSCustomObject]@{ key = [string]$record.key; sha256 = Get-DshKnownGoodHash -Path $target })
  }
  if ($null -ne $paths.guardStatePath) {
    $state = if ($null -ne $currentGuardState) { $currentGuardState } elseif ($null -ne $checkpointGuardState) { $checkpointGuardState } else { [PSCustomObject]@{ version = 1; profile = $Profile; failures = @(); quarantined = @(); lastRun = $null } }
    $state.profile = $Profile
    $state.quarantined = @($mergedQuarantine)
    if ($null -eq $state.failures) { $state.failures = @() }
    Write-DshKnownGoodJson -Path $paths.guardStatePath -Value $state
  }
  if ($null -ne $paths.guardPatchPath) {
    Write-DshKnownGoodGuardPatch -Path $paths.guardPatchPath -Entries $mergedQuarantine
  }
  $web = Test-DshKnownGoodWeb -BaseUrl $BaseUrl -FailedPluginId $FailedPluginId
  $profileValid = $true
  foreach ($record in $records | Where-Object { $_.exists }) {
    $target = Join-Path $paths.dshHome ([string]$record.key)
    if ((Get-DshKnownGoodHash -Path $target) -cne [string]$record.sha256) { $profileValid = $false }
  }
  $failedPluginPreserved = $true
  if (-not [string]::IsNullOrWhiteSpace($FailedPluginId)) {
    $failedPluginPreserved = @($mergedQuarantine | Where-Object { $_.entryId -eq $FailedPluginId -or $_.patchEntryId -eq $FailedPluginId -or $_.moduleName -eq $FailedPluginId }).Count -gt 0
  }
  $webValid = $web.status -in @('not-requested', 'ready')
  $healthy = $profileValid -and $failedPluginPreserved -and $webValid
  $nextRestoreCount = $restoreCount
  if ($Automatic) { $nextRestoreCount = $restoreCount + 1 }
  $nextStatus = 'MANUAL_REVIEW'
  if ($healthy) { $nextStatus = 'healthy' }
  $nextRestoreMode = 'manual'
  if ($Automatic) { $nextRestoreMode = 'automatic' }
  Set-DshKnownGoodProperty -Object $manifest -Name 'automaticRestoreCount' -Value $nextRestoreCount
  Set-DshKnownGoodProperty -Object $manifest -Name 'status' -Value $nextStatus
  Set-DshKnownGoodProperty -Object $manifest -Name 'lastRestoreAt' -Value ((Get-Date).ToUniversalTime().ToString('o'))
  Set-DshKnownGoodProperty -Object $manifest -Name 'lastRestoreMode' -Value $nextRestoreMode
  Set-DshKnownGoodProperty -Object $manifest -Name 'lastValidation' -Value ([ordered]@{
    profileHashes = $profileValid
    failedPluginPreserved = $failedPluginPreserved
    web = $web
    workspaceTouched = $false
  })
  Write-DshKnownGoodJson -Path (Join-Path $checkpointPath 'manifest.json') -Value $manifest
  return [PSCustomObject]@{
    result = if ($healthy) { 'PASS' } else { 'MANUAL_REVIEW' }
    status = [string](Get-DshKnownGoodProperty -Object $manifest -Name 'status')
    checkpointId = $CheckpointId
    restored = @($restored)
    conflicts = @($conflicts)
    failedPluginPreserved = $failedPluginPreserved
    automaticRestoreCount = [int](Get-DshKnownGoodProperty -Object $manifest -Name 'automaticRestoreCount')
    web = $web
    validation = Get-DshKnownGoodProperty -Object $manifest -Name 'lastValidation'
    workspaceTouched = $false
  }
}

Export-ModuleMember -Function @(
  'Save-DshKnownGoodCheckpoint',
  'Get-DshKnownGoodCheckpoints',
  'Restore-DshKnownGoodCheckpoint',
  'Test-DshKnownGoodWeb'
)
