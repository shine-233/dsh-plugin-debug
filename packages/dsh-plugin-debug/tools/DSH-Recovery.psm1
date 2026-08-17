Set-StrictMode -Version Latest

function Resolve-DshRecoveryHome {
  param(
    [string]$DshHome = '',
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$SnapshotRoot = ''
  )
  if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
      Join-Path $env:USERPROFILE '.dsh'
    } else {
      $env:DSH_HOME
    }
  }
  $resolvedHome = [IO.Path]::GetFullPath($DshHome)
  if ([string]::IsNullOrWhiteSpace($SnapshotRoot)) {
    $SnapshotRoot = Join-Path $resolvedHome "recovery\profiles\$Profile"
  }
  return [PSCustomObject]@{
    dshHome = $resolvedHome
    profile = $Profile
    profileRoot = Join-Path $resolvedHome "profiles\$Profile"
    snapshotRoot = [IO.Path]::GetFullPath($SnapshotRoot)
  }
}

function Get-DshRecoveryFileDefinitions {
  param([Parameter(Mandatory = $true)][string]$Profile)
  return @(
    [PSCustomObject]@{ relativePath = "profiles\$Profile\package.json"; sensitive = $false }
    [PSCustomObject]@{ relativePath = "profiles\$Profile\cordis.yml"; sensitive = $false }
    [PSCustomObject]@{ relativePath = "profiles\$Profile\cordis.patch.yml"; sensitive = $false }
    [PSCustomObject]@{ relativePath = "profiles\$Profile\pnpm-workspace.yaml"; sensitive = $false }
    [PSCustomObject]@{ relativePath = 'settings.yaml'; sensitive = $false }
    [PSCustomObject]@{ relativePath = '.env'; sensitive = $true }
    [PSCustomObject]@{ relativePath = '.credentials.yaml'; sensitive = $true }
    [PSCustomObject]@{ relativePath = '.credentials.yml'; sensitive = $true }
    [PSCustomObject]@{ relativePath = '.credentials'; sensitive = $true }
  )
}

function Test-DshPathWithin {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$CandidatePath
  )
  $base = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $candidate = [IO.Path]::GetFullPath($CandidatePath)
  return $candidate.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
    $candidate -eq $base.TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Get-DshRecoveryHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Test-DshRecoverySensitivePath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $leaf = Split-Path -Leaf $RelativePath
  return $leaf -match '^(?i:\.env(?:\..*)?|\.credentials(?:\..*)?)$'
}

function Write-DshRecoveryJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-DshRecoveryManifest {
  param(
    [Parameter(Mandatory = $true)][string]$SnapshotRoot,
    [Parameter(Mandatory = $true)][string]$SnapshotId
  )
  if ($SnapshotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') {
    throw "invalid snapshot id: $SnapshotId"
  }
  $root = [IO.Path]::GetFullPath($SnapshotRoot)
  $path = Join-Path (Join-Path $root $SnapshotId) 'manifest.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-DshPathWithin -BasePath $root -CandidatePath $path)) {
    throw "snapshot manifest does not exist: $path"
  }
  $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([int]$manifest.schemaVersion -ne 1) { throw "unsupported DSH recovery snapshot schema: $($manifest.schemaVersion)" }
  return $manifest
}

function Save-DshProfileSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$DshHome = '',
    [string]$SnapshotRoot = '',
    [string]$Label = 'manual'
  )
  $paths = Resolve-DshRecoveryHome -DshHome $DshHome -Profile $Profile -SnapshotRoot $SnapshotRoot
  if (-not (Test-Path -LiteralPath $paths.dshHome -PathType Container)) {
    throw "DSH_HOME does not exist: $($paths.dshHome)"
  }
  if (-not (Test-Path -LiteralPath $paths.profileRoot -PathType Container)) {
    throw "profile does not exist: $($paths.profileRoot)"
  }
  $snapshotId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $snapshotPath = Join-Path $paths.snapshotRoot $snapshotId
  New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null
  $records = @()
  try {
    foreach ($definition in Get-DshRecoveryFileDefinitions -Profile $Profile) {
      $source = Join-Path $paths.dshHome $definition.relativePath
      $destination = Join-Path $snapshotPath $definition.relativePath
      $exists = Test-Path -LiteralPath $source -PathType Leaf
      $record = [ordered]@{
        relativePath = [string]$definition.relativePath
        sensitive = [bool]$definition.sensitive
        exists = $exists
        captured = $false
        excluded = $false
        exclusionReason = $null
        length = $null
        sha256 = $null
      }
      if ($exists) {
        if (-not (Test-DshPathWithin -BasePath $paths.dshHome -CandidatePath $source)) {
          throw "recovery source escaped DSH_HOME: $source"
        }
        if ([bool]$definition.sensitive -or (Test-DshRecoverySensitivePath -RelativePath $definition.relativePath)) {
          $record.excluded = $true
          $record.exclusionReason = 'sensitive-content-not-captured'
        } else {
          $parent = Split-Path -Parent $destination
          New-Item -ItemType Directory -Path $parent -Force | Out-Null
          Copy-Item -LiteralPath $source -Destination $destination -Force
          $item = Get-Item -LiteralPath $source -Force
          $record.captured = $true
          $record.length = [int64]$item.Length
          $record.sha256 = Get-DshRecoveryHash -Path $source
        }
      }
      $records += [PSCustomObject]$record
    }
    $manifest = [ordered]@{
      schemaVersion = 1
      id = $snapshotId
      profile = $Profile
      createdAt = (Get-Date).ToUniversalTime().ToString('o')
      label = $Label
      dshHome = $paths.dshHome
      files = $records
      safety = [ordered]@{
        restoreDeletesFiles = $false
        restoreCreatesRescuePoint = $true
        sensitiveFilesIncluded = @()
        sensitiveFilesExcluded = @($records | Where-Object { $_.sensitive -and $_.exists } | ForEach-Object { $_.relativePath })
        sensitiveContentCaptured = $false
      }
    }
    Write-DshRecoveryJson -Path (Join-Path $snapshotPath 'manifest.json') -Value $manifest
    return [PSCustomObject]@{
      id = $snapshotId
      path = $snapshotPath
      profile = $Profile
      files = @($records | Where-Object { $_.captured } | ForEach-Object { $_.relativePath })
      sensitiveFiles = @($records | Where-Object { $_.sensitive -and $_.exists } | ForEach-Object { $_.relativePath })
    }
  } catch {
    if (Test-Path -LiteralPath $snapshotPath -PathType Container) {
      Remove-Item -LiteralPath $snapshotPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

function Get-DshProfileSnapshots {
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$DshHome = '',
    [string]$SnapshotRoot = ''
  )
  $paths = Resolve-DshRecoveryHome -DshHome $DshHome -Profile $Profile -SnapshotRoot $SnapshotRoot
  if (-not (Test-Path -LiteralPath $paths.snapshotRoot -PathType Container)) { return @() }
  $items = @()
  foreach ($directory in @(Get-ChildItem -LiteralPath $paths.snapshotRoot -Directory -Force | Sort-Object Name -Descending)) {
    $manifestPath = Join-Path $directory.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $items += [PSCustomObject]@{
        id = [string]$manifest.id
        profile = [string]$manifest.profile
        createdAt = [string]$manifest.createdAt
        label = [string]$manifest.label
        path = $directory.FullName
        fileCount = @($manifest.files | Where-Object { $_.exists -and (-not $_.sensitive) }).Count
        sensitiveFileCount = @($manifest.files | Where-Object { $_.sensitive -and $_.exists }).Count
      }
    } catch {
      $items += [PSCustomObject]@{ id = $directory.Name; path = $directory.FullName; unreadable = $true }
    }
  }
  return $items
}

function Restore-DshProfileSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$SnapshotId,
    [string]$DshHome = '',
    [string]$SnapshotRoot = '',
    [switch]$NoRescue
  )
  $paths = Resolve-DshRecoveryHome -DshHome $DshHome -Profile $Profile -SnapshotRoot $SnapshotRoot
  $manifest = Read-DshRecoveryManifest -SnapshotRoot $paths.snapshotRoot -SnapshotId $SnapshotId
  if ([string]$manifest.profile -cne $Profile) { throw "snapshot belongs to profile '$($manifest.profile)', not '$Profile'" }
  $rescue = $null
  if (-not $NoRescue) {
    $rescue = Save-DshProfileSnapshot -Profile $Profile -DshHome $paths.dshHome -SnapshotRoot $paths.snapshotRoot -Label "rescue-before-restore:$SnapshotId"
  }
  $snapshotPath = Join-Path $paths.snapshotRoot $SnapshotId
  $restored = @()
  $skipped = @()
  foreach ($record in @($manifest.files)) {
    $relativePath = [string]$record.relativePath
    if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
    $source = Join-Path $snapshotPath $relativePath
    $target = Join-Path $paths.dshHome $relativePath
    if (-not (Test-DshPathWithin -BasePath $paths.snapshotRoot -CandidatePath $source) -or
        -not (Test-DshPathWithin -BasePath $paths.dshHome -CandidatePath $target)) {
      throw "recovery path escaped its root: $relativePath"
    }
    if ([bool]$record.sensitive -or (Test-DshRecoverySensitivePath -RelativePath $relativePath)) {
      $skipped += $relativePath
      continue
    }
    if (-not [bool]$record.exists) {
      $skipped += $relativePath
      continue
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "snapshot file is missing: $source" }
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
    $restored += [PSCustomObject]@{ relativePath = $relativePath; sha256 = Get-DshRecoveryHash -Path $target }
  }
  return [PSCustomObject]@{
    profile = $Profile
    snapshotId = $SnapshotId
    restored = $restored
    skippedMissingAtSnapshot = $skipped
    rescueSnapshot = if ($null -eq $rescue) { $null } else { $rescue.id }
    safety = 'Only files captured by the snapshot were overwritten; files absent from the snapshot were not deleted.'
  }
}

function Get-DshWorkspaceKey {
  param([Parameter(Mandatory = $true)][string]$Workspace)
  $bytes = [Text.Encoding]::UTF8.GetBytes($Workspace.ToLowerInvariant())
  $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
  return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}

function Resolve-DshWorkspaceRecoveryHome {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [string]$DshHome = '',
    [string]$SnapshotRoot = ''
  )
  $workspaceRoot = [IO.Path]::GetFullPath($Workspace).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
    throw "workspace does not exist: $workspaceRoot"
  }
  $workspaceItem = Get-Item -LiteralPath $workspaceRoot -Force -ErrorAction Stop
  if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "workspace root is a reparse point; refusing snapshot: $workspaceRoot"
  }
  if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  }
  $resolvedHome = [IO.Path]::GetFullPath($DshHome)
  if ([string]::IsNullOrWhiteSpace($SnapshotRoot)) {
    $SnapshotRoot = Join-Path $resolvedHome ("recovery\workspaces\" + (Get-DshWorkspaceKey -Workspace $workspaceRoot))
  }
  $resolvedSnapshotRoot = [IO.Path]::GetFullPath($SnapshotRoot)
  if (Test-DshPathWithin -BasePath $workspaceRoot -CandidatePath $resolvedSnapshotRoot) {
    throw "workspace snapshot root must be outside the workspace: $resolvedSnapshotRoot"
  }
  return [PSCustomObject]@{
    dshHome = $resolvedHome
    workspaceRoot = $workspaceRoot
    snapshotRoot = $resolvedSnapshotRoot
    workspaceKey = Get-DshWorkspaceKey -Workspace $workspaceRoot
  }
}

function Get-DshWorkspaceRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $base = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $candidate = [IO.Path]::GetFullPath($Path)
  if (-not (Test-DshPathWithin -BasePath $WorkspaceRoot -CandidatePath $candidate) -or $candidate -eq $WorkspaceRoot) {
    throw "path is outside workspace: $Path"
  }
  return $candidate.Substring($base.Length).Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
}

function Test-DshWorkspaceExcludedPath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $excludedNames = @('.git', 'node_modules', '.dsh', 'dist', 'build')
  $parts = $RelativePath -split '[\\/]'
  foreach ($part in $parts) {
    if ($excludedNames -contains $part) { return $true }
  }
  return $false
}

function Test-DshWorkspaceSensitivePath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $name = Split-Path -Leaf $RelativePath
  return $name -match '^(?i:\.env(?:\..*)?|.*\.(?:pem|key|p12|pfx))$' -or $name -match '^(?i:id_rsa(?:\..*)?)$'
}

function Get-DshWorkspaceTree {
  param([Parameter(Mandatory = $true)][string]$WorkspaceRoot)
  $root = Get-Item -LiteralPath $WorkspaceRoot -Force -ErrorAction Stop
  $queue = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
  $queue.Enqueue($root)
  $files = @()
  $excluded = @()
  while ($queue.Count -gt 0) {
    $directory = $queue.Dequeue()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
      $relative = Get-DshWorkspaceRelativePath -WorkspaceRoot $WorkspaceRoot -Path $item.FullName
      if (Test-DshWorkspaceExcludedPath -RelativePath $relative) {
        $excluded += [PSCustomObject]@{ relativePath = $relative; reason = 'excluded-directory' }
        continue
      }
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $excluded += [PSCustomObject]@{ relativePath = $relative; reason = 'reparse-point-not-followed' }
        continue
      }
      if ($item.PSIsContainer) {
        $queue.Enqueue([System.IO.DirectoryInfo]$item)
      } else {
        $files += $item
      }
    }
  }
  return [PSCustomObject]@{ files = @($files); excluded = @($excluded) }
}

function Test-DshWorkspaceRestoreParents {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )
  $parts = $RelativePath -split '[\\/]'
  $current = $WorkspaceRoot
  for ($index = 0; $index -lt ($parts.Count - 1); $index++) {
    $current = Join-Path $current $parts[$index]
    if (-not (Test-Path -LiteralPath $current)) { continue }
    $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "restore parent is a reparse point: $current"
    }
    if (-not $item.PSIsContainer) { throw "restore parent is not a directory: $current" }
  }
}

function Read-DshWorkspaceRecoveryManifest {
  param(
    [Parameter(Mandatory = $true)][string]$SnapshotRoot,
    [Parameter(Mandatory = $true)][string]$SnapshotId
  )
  if ($SnapshotId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') { throw "invalid workspace snapshot id: $SnapshotId" }
  $root = [IO.Path]::GetFullPath($SnapshotRoot)
  $path = Join-Path (Join-Path $root $SnapshotId) 'manifest.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-DshPathWithin -BasePath $root -CandidatePath $path)) {
    throw "workspace snapshot manifest does not exist: $path"
  }
  $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -ne 'workspace') {
    throw "unsupported DSH workspace snapshot schema: $path"
  }
  return $manifest
}

function Save-DshWorkspaceSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [string]$DshHome = '',
    [string]$SnapshotRoot = '',
    [string]$Label = 'manual'
  )
  $paths = Resolve-DshWorkspaceRecoveryHome -Workspace $Workspace -DshHome $DshHome -SnapshotRoot $SnapshotRoot
  $tree = Get-DshWorkspaceTree -WorkspaceRoot $paths.workspaceRoot
  $snapshotId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $snapshotPath = Join-Path $paths.snapshotRoot $snapshotId
  New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null
  $records = @()
  try {
    foreach ($file in @($tree.files)) {
      $relative = Get-DshWorkspaceRelativePath -WorkspaceRoot $paths.workspaceRoot -Path $file.FullName
      $destination = Join-Path $snapshotPath $relative
      if (-not (Test-DshPathWithin -BasePath $snapshotPath -CandidatePath $destination)) { throw "workspace snapshot path escaped root: $relative" }
      $parent = Split-Path -Parent $destination
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
      Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
      $records += [PSCustomObject][ordered]@{
        relativePath = $relative
        sensitive = Test-DshWorkspaceSensitivePath -RelativePath $relative
        length = [int64]$file.Length
        sha256 = Get-DshRecoveryHash -Path $file.FullName
      }
    }
    $manifest = [ordered]@{
      schemaVersion = 1
      kind = 'workspace'
      id = $snapshotId
      workspaceRoot = $paths.workspaceRoot
      workspaceKey = $paths.workspaceKey
      createdAt = (Get-Date).ToUniversalTime().ToString('o')
      label = $Label
      files = $records
      excluded = @($tree.excluded)
      safety = [ordered]@{
        restoreDeletesFiles = $false
        restoreCreatesRescuePoint = $true
        reparsePointsFollowed = $false
        excludedDirectories = @('.git', 'node_modules', '.dsh', 'dist', 'build')
        sensitiveFilesIncluded = @($records | Where-Object { $_.sensitive } | ForEach-Object { $_.relativePath })
      }
    }
    Write-DshRecoveryJson -Path (Join-Path $snapshotPath 'manifest.json') -Value $manifest
    return [PSCustomObject]@{
      id = $snapshotId
      path = $snapshotPath
      workspace = $paths.workspaceRoot
      fileCount = $records.Count
      sensitiveFileCount = @($records | Where-Object { $_.sensitive }).Count
      excludedCount = @($tree.excluded).Count
    }
  } catch {
    if (Test-Path -LiteralPath $snapshotPath -PathType Container) { Remove-Item -LiteralPath $snapshotPath -Recurse -Force -ErrorAction SilentlyContinue }
    throw
  }
}

function Get-DshWorkspaceSnapshots {
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [string]$DshHome = '',
    [string]$SnapshotRoot = ''
  )
  $paths = Resolve-DshWorkspaceRecoveryHome -Workspace $Workspace -DshHome $DshHome -SnapshotRoot $SnapshotRoot
  if (-not (Test-Path -LiteralPath $paths.snapshotRoot -PathType Container)) { return @() }
  $items = @()
  foreach ($directory in @(Get-ChildItem -LiteralPath $paths.snapshotRoot -Directory -Force | Sort-Object Name -Descending)) {
    $manifestPath = Join-Path $directory.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$manifest.kind -ne 'workspace') { continue }
      $items += [PSCustomObject]@{
        id = [string]$manifest.id
        workspace = [string]$manifest.workspaceRoot
        createdAt = [string]$manifest.createdAt
        label = [string]$manifest.label
        path = $directory.FullName
        fileCount = @($manifest.files).Count
        sensitiveFileCount = @($manifest.files | Where-Object { $_.sensitive }).Count
        excludedCount = @($manifest.excluded).Count
      }
    } catch {
      $items += [PSCustomObject]@{ id = $directory.Name; path = $directory.FullName; unreadable = $true }
    }
  }
  return $items
}

function Restore-DshWorkspaceSnapshot {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$SnapshotId,
    [string]$DshHome = '',
    [string]$SnapshotRoot = '',
    [switch]$NoRescue
  )
  $paths = Resolve-DshWorkspaceRecoveryHome -Workspace $Workspace -DshHome $DshHome -SnapshotRoot $SnapshotRoot
  $manifest = Read-DshWorkspaceRecoveryManifest -SnapshotRoot $paths.snapshotRoot -SnapshotId $SnapshotId
  if ([string]$manifest.workspaceRoot -cne $paths.workspaceRoot) {
    throw "workspace snapshot belongs to '$($manifest.workspaceRoot)', not '$($paths.workspaceRoot)'; refusing cross-workspace restore"
  }
  $rescue = $null
  if (-not $NoRescue) {
    $rescue = Save-DshWorkspaceSnapshot -Workspace $paths.workspaceRoot -DshHome $paths.dshHome -SnapshotRoot $paths.snapshotRoot -Label "rescue-before-restore:$SnapshotId"
  }
  $snapshotPath = Join-Path $paths.snapshotRoot $SnapshotId
  $restored = @()
  foreach ($record in @($manifest.files)) {
    $relative = [string]$record.relativePath
    if ([string]::IsNullOrWhiteSpace($relative) -or (Test-DshWorkspaceExcludedPath -RelativePath $relative)) { continue }
    $source = Join-Path $snapshotPath $relative
    $target = Join-Path $paths.workspaceRoot $relative
    if (-not (Test-DshPathWithin -BasePath $snapshotPath -CandidatePath $source) -or -not (Test-DshPathWithin -BasePath $paths.workspaceRoot -CandidatePath $target)) {
      throw "workspace restore path escaped its root: $relative"
    }
    Test-DshWorkspaceRestoreParents -WorkspaceRoot $paths.workspaceRoot -RelativePath $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "workspace snapshot file is missing: $source" }
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
    $hash = Get-DshRecoveryHash -Path $target
    if ([string]$hash -cne [string]$record.sha256) { throw "workspace restore hash verification failed: $relative" }
    $restored += [PSCustomObject]@{ relativePath = $relative; sha256 = $hash }
  }
  return [PSCustomObject]@{
    workspace = $paths.workspaceRoot
    snapshotId = $SnapshotId
    restored = $restored
    rescueSnapshot = if ($null -eq $rescue) { $null } else { $rescue.id }
    safety = 'Only captured workspace files were overwritten; files absent from the snapshot were not deleted; excluded and reparse paths were not followed.'
  }
}

function Get-DshSafeCallId {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  if ($Value.Length -le 80) { return $Value }
  return $Value.Substring(0, 77) + '...'
}

function Get-DshSessionHistoryObservation {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [int]$MaxMessages = 100
  )
  if ($MaxMessages -lt 1 -or $MaxMessages -gt 500) { throw 'MaxMessages must be between 1 and 500' }
  $history = Invoke-DshGuardApi -BaseUrl $BaseUrl -Method 'session.history' -Arguments @{
    sessionId = $SessionId
    maxMessages = $MaxMessages
  } -TimeoutSec 8
  $events = @($history.events | ForEach-Object { $_.event })
  $rows = @()
  foreach ($event in $events) {
    if ($null -eq $event) { continue }
    $type = [string]$event.type
    $data = $event.data
    $row = [ordered]@{
      seq = if ($null -eq $event.seq) { $null } else { [int]$event.seq }
      type = $type
      turn = if ($null -eq $data.turn) { $null } else { [int]$data.turn }
      step = if ($null -eq $data.step) { $null } else { [int]$data.step }
    }
    switch ($type) {
      'user/message' {
        $row.contentObserved = $null -ne $data.message -or $null -ne $data.content
        $row.contentBody = 'omitted-by-default'
      }
      'request/context' {
        $row.provider = [string]$data.provider
        $row.model = [string]$data.model
      }
      'tool/call' {
        $row.name = [string]$data.name
        $row.callId = Get-DshSafeCallId -Value ([string]$data.callId)
        $row.argumentsObserved = $null -ne $data.arguments
      }
      'tool/result' {
        $message = $data.message
        $row.callId = Get-DshSafeCallId -Value ([string]$message.source.callId)
        $blocks = @($message.content | Where-Object { $_.type -eq 'tool-result' })
        $row.isError = @($blocks | Where-Object { $_.isError -eq $true }).Count -gt 0
        $row.resultBody = 'omitted-by-default'
      }
      'turn/end' {
        $row.reasonKind = [string]$data.reason.kind
      }
    }
    $rows += [PSCustomObject]$row
  }
  return [PSCustomObject]@{
    status = 'observed'
    sessionId = $SessionId
    eventCount = $rows.Count
    hasMore = $history.hasMore -eq $true
    events = $rows
    privacy = 'Message text, Tool arguments, Tool results, credentials, cookies, authorization headers, and full cwd are omitted.'
  }
}

function Invoke-DshSessionFork {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Nullable[int]]$AtSeq
  )
  if ($null -eq $AtSeq) { throw 'AtSeq is required for session-fork' }
  if ([int]$AtSeq -lt 0) { throw 'AtSeq must be non-negative' }
  $arguments = @{ sessionId = $SessionId }
  $arguments.atSeq = [int]$AtSeq
  $value = Invoke-DshGuardApi -BaseUrl $BaseUrl -Method 'session.fork' -Arguments $arguments -TimeoutSec 8
  $childProperty = $value.PSObject.Properties['sessionId']
  if ($null -eq $childProperty -or [string]::IsNullOrWhiteSpace([string]$childProperty.Value)) {
    throw 'session.fork returned success without child Session ID'
  }
  return [PSCustomObject]@{
    status = 'forked'
    sourceSessionId = $SessionId
    atSeq = [int]$AtSeq
    childSessionId = [string]$childProperty.Value
    semantics = 'Append-only branch: the source session is retained and no workspace files are changed.'
  }
}

Export-ModuleMember -Function @(
  'Resolve-DshRecoveryHome',
  'Get-DshRecoveryFileDefinitions',
  'Save-DshProfileSnapshot',
  'Get-DshProfileSnapshots',
  'Restore-DshProfileSnapshot',
  'Save-DshWorkspaceSnapshot',
  'Get-DshWorkspaceSnapshots',
  'Restore-DshWorkspaceSnapshot',
  'Get-DshSessionHistoryObservation',
  'Invoke-DshSessionFork'
)
