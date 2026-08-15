[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [string]$OutputPath = '',
  [string]$PackageRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxInputBytes = 4MB
$script:MaxNodes = 1000
$script:MaxEdges = 5000

function Get-DshDependencyProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
    return $Object[$Name]
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function ConvertTo-DshDependencyId {
  param([AllowEmptyString()][string]$Value)
  $id = $Value.Trim()
  if ($id -match '^(?i:include:)(.+)$') { return $Matches[1] }
  return $id
}

function Get-DshDependencyMapEntries {
  param([AllowNull()]$Object)
  if ($null -eq $Object) { return @() }
  $entries = [System.Collections.Generic.List[object]]::new()
  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($key in @($Object.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      [void]$entries.Add([PSCustomObject]@{ name = $key; value = $Object[$key] })
    }
    return @($entries)
  }
  # Windows PowerShell 5.1 can expose adapter members when a generated JSON
  # object is traversed through PSObject.Properties. Read the property
  # metadata explicitly and sort the normalized entries, rather than sorting
  # the adapter collection by a possibly missing Name member.
  $propertyEntries = foreach ($property in @($Object.PSObject.Properties)) {
    $propertyName = Get-DshDependencyProperty -Object $property -Name 'Name'
    $propertyValue = Get-DshDependencyProperty -Object $property -Name 'Value'
    if ($null -eq $propertyName) { continue }
    [PSCustomObject]@{ name = [string]$propertyName; value = $propertyValue }
  }
  foreach ($entry in @($propertyEntries | Sort-Object -Property name)) {
    [void]$entries.Add($entry)
  }
  return @($entries)
}

function Get-DshDependencyManifest {
  param([Parameter(Mandatory = $true)]$InputObject)
  $manifest = Get-DshDependencyProperty -Object $InputObject -Name 'profileManifest'
  if ($null -eq $manifest) { $manifest = Get-DshDependencyProperty -Object $InputObject -Name 'manifest' }
  if ($null -eq $manifest -and $null -ne (Get-DshDependencyProperty -Object $InputObject -Name 'dependencies')) {
    $manifest = $InputObject
  }
  if ($null -eq $manifest) { throw 'dependency graph input must contain profileManifest or manifest' }
  return $manifest
}

function Get-DshDependencyMetadataMap {
  param([Parameter(Mandatory = $true)]$InputObject)
  $packages = Get-DshDependencyProperty -Object $InputObject -Name 'packages'
  if ($null -eq $packages) { $packages = Get-DshDependencyProperty -Object $InputObject -Name 'packageMetadata' }
  if ($null -eq $packages) { $packages = Get-DshDependencyProperty -Object $InputObject -Name 'packageManifests' }
  $metadata = [ordered]@{}
  if ($null -eq $packages) { return $metadata }

  if ($packages -is [System.Collections.IDictionary]) {
    foreach ($key in @($packages.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      $value = $packages[$key]
      $name = [string](Get-DshDependencyProperty -Object $value -Name 'name')
      if ([string]::IsNullOrWhiteSpace($name)) { $name = $key }
      $normalized = ConvertTo-DshDependencyId -Value $name
      if (-not [string]::IsNullOrWhiteSpace($normalized)) { $metadata[$normalized] = $value }
    }
    return $metadata
  }

  $packageValues = @()
  if ($packages -is [System.Array]) {
    $packageValues = @($packages | ForEach-Object { [PSCustomObject]@{ key = ''; value = $_ } })
  } elseif ($null -ne (Get-DshDependencyProperty -Object $packages -Name 'name')) {
    $packageValues = @([PSCustomObject]@{ key = ''; value = $packages })
  } else {
    $packageValues = @(Get-DshDependencyMapEntries -Object $packages | ForEach-Object {
      [PSCustomObject]@{ key = [string]$_.name; value = $_.value }
    })
  }
  foreach ($packageValue in $packageValues) {
    $value = $packageValue.value
    if ($null -eq $value) { continue }
    $name = [string](Get-DshDependencyProperty -Object $value -Name 'name')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-DshDependencyProperty -Object $value -Name 'id') }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-DshDependencyProperty -Object $value -Name 'packageName') }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$packageValue.key }
    $normalized = ConvertTo-DshDependencyId -Value $name
    if (-not [string]::IsNullOrWhiteSpace($normalized)) { $metadata[$normalized] = $value }
  }
  return $metadata
}

function Get-DshDependencySpecKind {
  param([AllowNull()]$Value)
  $spec = if ($null -eq $Value) { '' } else { [string]$Value }
  if ([string]::IsNullOrWhiteSpace($spec)) { return 'unspecified' }
  if ($spec -match '^(?i:workspace):') { return 'workspace' }
  if ($spec -match '^(?i:(file|link)):') { return 'local-path' }
  if ($spec -match '^(?i:(https?|git|git\+|ssh)):') { return 'external-reference' }
  if ($spec -match '^[A-Za-z]:[\\/]|^[/\\]') { return 'absolute-path' }
  if ($spec -match '[\\/]') { return 'relative-path' }
  return 'version-range'
}

function Get-DshDependencyFilesystemInput {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$PackageRoot = ''
  )
  $manifestPath = Join-Path $Root 'package.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'package.json is missing' }
  $profileManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $metadata = [ordered]@{}
  $scanRoots = [System.Collections.Generic.List[string]]::new()
  [void]$scanRoots.Add([IO.Path]::GetFullPath((Join-Path $Root 'node_modules')))
  if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    [void]$scanRoots.Add([IO.Path]::GetFullPath($PackageRoot))
    [void]$scanRoots.Add([IO.Path]::GetFullPath((Join-Path $PackageRoot 'node_modules')))
  }
  foreach ($scanRoot in @($scanRoots | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $scanRoot -PathType Container)) { continue }
    foreach ($directory in @(Get-ChildItem -LiteralPath $scanRoot -Directory -Force -ErrorAction SilentlyContinue)) {
      $candidatePaths = [System.Collections.Generic.List[string]]::new()
      if ($directory.Name.StartsWith('@')) {
        foreach ($scoped in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
          [void]$candidatePaths.Add((Join-Path $scoped.FullName 'package.json'))
        }
      } else {
        [void]$candidatePaths.Add((Join-Path $directory.FullName 'package.json'))
      }
      foreach ($candidate in @($candidatePaths)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try { $packageManifest = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $name = [string](Get-DshDependencyProperty -Object $packageManifest -Name 'name')
        if (-not [string]::IsNullOrWhiteSpace($name)) { $metadata[(ConvertTo-DshDependencyId -Value $name)] = $packageManifest }
      }
    }
  }
  return [ordered]@{ profileManifest = $profileManifest; packages = $metadata }
}

function Get-DshDependencyProtectedReason {
  param([Parameter(Mandatory = $true)][string]$Id)
  if ($Id -match '^(?i:@deepseek-ai/)') { return 'core-package' }
  if ($Id -match '^(?i:(runtime:|runtime/))') { return 'runtime-entry' }
  return $null
}

function Add-DshDependencyNode {
  param(
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Nodes,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$SpecKind,
    [Parameter(Mandatory = $true)][bool]$MetadataPresent
  )
  if ($Nodes.Contains($Id)) {
    $existing = $Nodes[$Id]
    if ($MetadataPresent) { $existing.metadataPresent = $true }
    if ($existing.kind -ne 'profile' -and $Kind -eq 'profile') { $existing.kind = $Kind }
    if ($existing.versionSpecKind -eq 'unspecified' -and $SpecKind -ne 'unspecified') { $existing.versionSpecKind = $SpecKind }
    return
  }
  $protectedReason = Get-DshDependencyProtectedReason -Id $Id
  $Nodes[$Id] = [ordered]@{
    id = $Id
    kind = $Kind
    metadataPresent = $MetadataPresent
    versionSpecKind = $SpecKind
    protected = $null -ne $protectedReason
    protectedReason = $protectedReason
  }
}

function Add-DshDependencyEdge {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Edges,
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Seen,
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [Parameter(Mandatory = $true)][string]$Relation,
    [Parameter(Mandatory = $true)][string]$SpecKind
  )
  $key = "$From`u{0}$To`u{0}$Relation"
  if ($Seen.Contains($key)) { return }
  $Seen[$key] = $true
  if ($Edges.Count -ge $script:MaxEdges) { throw "dependency graph exceeds $script:MaxEdges edges" }
  [void]$Edges.Add([ordered]@{
    from = $From
    to = $To
    relation = $Relation
    specKind = $SpecKind
  })
}

function Get-DshDependencyRelations {
  param([Parameter(Mandatory = $true)]$Object)
  foreach ($relation in @('dependencies', 'optionalDependencies', 'peerDependencies')) {
    $map = Get-DshDependencyProperty -Object $Object -Name $relation
    foreach ($entry in @(Get-DshDependencyMapEntries -Object $map)) {
      $id = ConvertTo-DshDependencyId -Value ([string]$entry.name)
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      [PSCustomObject]@{
        id = $id
        relation = $relation
        specKind = Get-DshDependencySpecKind -Value $entry.value
      }
    }
  }
}

function Get-DshDependencyCanonicalCycle {
  param([Parameter(Mandatory = $true)][string[]]$Cycle)
  $body = @($Cycle[0..($Cycle.Count - 2)])
  $rotations = [System.Collections.Generic.List[object]]::new()
  for ($index = 0; $index -lt $body.Count; $index++) {
    if ($index -eq 0) {
      $rotation = @($body)
    } else {
      $rotation = @($body[$index..($body.Count - 1)]) + @($body[0..($index - 1)])
    }
    [void]$rotations.Add([PSCustomObject]@{ key = ($rotation -join '>'); values = $rotation })
  }
  $canonical = $rotations | Sort-Object key | Select-Object -First 1
  return @($canonical.values) + @($canonical.values[0])
}

function Find-DshDependencyCycles {
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Adjacency)
  $script:DependencyGraphAdjacency = $Adjacency
  $script:DependencyGraphPath = [System.Collections.Generic.List[string]]::new()
  $script:DependencyGraphPathIndex = @{}
  $script:DependencyGraphCycles = [System.Collections.Generic.List[object]]::new()
  $script:DependencyGraphCycleSeen = @{}
  function Visit-DshDependencyCycle {
    param([Parameter(Mandatory = $true)][string]$Node)
    if ($script:DependencyGraphPathIndex.ContainsKey($Node)) { return }
    $script:DependencyGraphPathIndex[$Node] = $script:DependencyGraphPath.Count
    [void]$script:DependencyGraphPath.Add($Node)
    $neighbors = if ($script:DependencyGraphAdjacency.Contains($Node)) { @($script:DependencyGraphAdjacency[$Node] | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
    foreach ($neighbor in $neighbors) {
      if ($script:DependencyGraphPathIndex.ContainsKey($neighbor)) {
        $cycleStart = [int]$script:DependencyGraphPathIndex[$neighbor]
        $cycle = @($script:DependencyGraphPath.ToArray()[$cycleStart..($script:DependencyGraphPath.Count - 1)]) + @($neighbor)
        $canonical = @(Get-DshDependencyCanonicalCycle -Cycle ([string[]]$cycle))
        $key = $canonical -join '>'
        if (-not $script:DependencyGraphCycleSeen.ContainsKey($key)) {
          $script:DependencyGraphCycleSeen[$key] = $true
          [void]$script:DependencyGraphCycles.Add([ordered]@{ nodes = @($canonical); length = $canonical.Count - 1 })
        }
      } else {
        [void](Visit-DshDependencyCycle -Node $neighbor)
      }
    }
    $script:DependencyGraphPathIndex.Remove($Node)
    [void]$script:DependencyGraphPath.RemoveAt($script:DependencyGraphPath.Count - 1)
  }
  foreach ($start in @($Adjacency.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { [void](Visit-DshDependencyCycle -Node $start) }
  $sortedCycles = @($script:DependencyGraphCycles | Sort-Object { $_.nodes -join '>' })
  foreach ($cycle in $sortedCycles) { Write-Output -NoEnumerate $cycle }
}

function Write-DshDependencyReport {
  param([Parameter(Mandatory = $true)]$Report, [string]$Path = '')
  $json = $Report | ConvertTo-Json -Depth 30
  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
  }
  $json
}

try {
  if (-not (Test-Path -LiteralPath $InputPath -PathType Any)) { throw 'dependency graph input does not exist' }
  $inputItem = Get-Item -LiteralPath $InputPath -Force
  if ($inputItem.PSIsContainer) {
    $inputObject = Get-DshDependencyFilesystemInput -Root $inputItem.FullName -PackageRoot $PackageRoot
  } else {
    if ($inputItem.Length -gt $script:MaxInputBytes) { throw 'dependency graph input exceeds the size limit' }
    $inputObject = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $inputObject -or $inputObject -is [System.Array]) { throw 'dependency graph input must be a JSON object' }
  }

  $manifest = Get-DshDependencyManifest -InputObject $inputObject
  $metadata = Get-DshDependencyMetadataMap -InputObject $inputObject
  $nodes = [ordered]@{}
  $edges = [System.Collections.Generic.List[object]]::new()
  $edgeSeen = @{}
  $queue = [System.Collections.Generic.Queue[string]]::new()
  $queued = @{}
  $profileName = [string](Get-DshDependencyProperty -Object $manifest -Name 'name')
  if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = 'profile' }
  $profileId = 'profile:' + $profileName
  Add-DshDependencyNode -Nodes $nodes -Id $profileId -Kind 'profile' -SpecKind 'unspecified' -MetadataPresent $true

  foreach ($relation in @(Get-DshDependencyRelations -Object $manifest)) {
    Add-DshDependencyNode -Nodes $nodes -Id $relation.id -Kind 'package' -SpecKind $relation.specKind -MetadataPresent $metadata.Contains($relation.id)
    Add-DshDependencyEdge -Edges $edges -Seen $edgeSeen -From $profileId -To $relation.id -Relation "profile.$($relation.relation)" -SpecKind $relation.specKind
    if (-not $queued.ContainsKey($relation.id)) { $queued[$relation.id] = $true; $queue.Enqueue($relation.id) }
  }

  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if ($metadata.Contains($id)) {
      foreach ($relation in @(Get-DshDependencyRelations -Object $metadata[$id])) {
        Add-DshDependencyNode -Nodes $nodes -Id $relation.id -Kind 'package' -SpecKind $relation.specKind -MetadataPresent $metadata.Contains($relation.id)
        Add-DshDependencyEdge -Edges $edges -Seen $edgeSeen -From $id -To $relation.id -Relation $relation.relation -SpecKind $relation.specKind
        if (-not $queued.ContainsKey($relation.id)) { $queued[$relation.id] = $true; $queue.Enqueue($relation.id) }
      }
    }
    if ($nodes.Count -gt $script:MaxNodes) { throw "dependency graph exceeds $script:MaxNodes nodes" }
  }

  $missingSeen = @{}
  $missing = [System.Collections.Generic.List[object]]::new()
  foreach ($edge in @($edges)) {
    if ($edge.to -eq $profileId -or $metadata.Contains([string]$edge.to)) { continue }
    $key = "$($edge.from)>$($edge.to)>$($edge.relation)"
    if ($missingSeen.ContainsKey($key)) { continue }
    $missingSeen[$key] = $true
    [void]$missing.Add([ordered]@{
      from = [string]$edge.from
      to = [string]$edge.to
      name = [string]$edge.to
      relation = [string]$edge.relation
      specKind = [string]$edge.specKind
      reason = 'package-metadata-missing'
    })
  }

  $adjacency = @{}
  foreach ($edge in @($edges)) {
    if (-not $adjacency.ContainsKey([string]$edge.from)) { $adjacency[[string]$edge.from] = [System.Collections.Generic.List[string]]::new() }
    if (-not @($adjacency[[string]$edge.from]) -contains [string]$edge.to) { [void]$adjacency[[string]$edge.from].Add([string]$edge.to) }
  }
  $cycles = @(Find-DshDependencyCycles -Adjacency $adjacency)
  $unreferenced = [System.Collections.Generic.List[object]]::new()
  foreach ($metadataName in @($metadata.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
    if (-not $nodes.Contains($metadataName)) {
      [void]$unreferenced.Add([ordered]@{
        id = $metadataName
        protected = $null -ne (Get-DshDependencyProtectedReason -Id $metadataName)
        reason = 'local-package-not-reachable-from-profile'
      })
    }
  }
  $protectedCore = @($nodes.Values | Where-Object { $_.protected -eq $true } | ForEach-Object {
    [ordered]@{ id = [string]$_.id; reason = [string]$_.protectedReason }
  } | Sort-Object id)
  $missingOutput = @($missing | Sort-Object from, to, relation)
  $edgesOutput = @($edges | Sort-Object from, to, relation)
  $nodesOutput = @($nodes.Values | Sort-Object id)
  $unreferencedOutput = @($unreferenced | Sort-Object id)
  $issueCodes = [System.Collections.Generic.List[string]]::new()
  if ($missingOutput.Count -gt 0) { [void]$issueCodes.Add('MISSING_DEPENDENCY') }
  if ($cycles.Count -gt 0) { [void]$issueCodes.Add('DEPENDENCY_CYCLE') }
  if ($unreferencedOutput.Count -gt 0) { [void]$issueCodes.Add('UNREFERENCED_LOCAL_PACKAGE') }
  if ($issueCodes.Count -eq 0) { [void]$issueCodes.Add('NONE') }
  $hasFinding = $issueCodes.Count -gt 1
  $report = [ordered]@{
    kind = 'dsh-plugin-dependency-graph'
    schemaVersion = 1
    result = if ($hasFinding) { 'FAIL' } else { 'PASS' }
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    offline = $true
    networkAccessed = $false
    readOnly = $true
    executesPackageCode = $false
    autoInstall = $false
    nodes = $nodesOutput
    edges = $edgesOutput
    missing = $missingOutput
    cycles = $cycles
    unreferenced = $unreferencedOutput
    protectedCore = $protectedCore
    issueCodes = @($issueCodes)
    summary = [ordered]@{
      rootCount = @(Get-DshDependencyRelations -Object $manifest).Count
      nodeCount = $nodesOutput.Count
      edgeCount = $edgesOutput.Count
      missingCount = $missingOutput.Count
      cycleCount = $cycles.Count
      unreferencedCount = $unreferencedOutput.Count
      protectedCoreCount = $protectedCore.Count
    }
    safety = [ordered]@{
      profileChanged = $false
      workspaceChanged = $false
      commandsExecuted = $false
      pluginsExecuted = $false
      automaticAction = 'none'
    }
    privacy = [ordered]@{
      metadataOnly = $true
      rawInputStored = $false
      pathsStored = $false
      commandsStored = $false
      credentialsStored = $false
      networkPayloadSent = $false
    }
  }
  Write-DshDependencyReport -Report $report -Path $OutputPath
  $exitCode = if ($hasFinding) { 1 } else { 0 }
  exit $exitCode
} catch {
  [ordered]@{
    kind = 'dsh-plugin-dependency-graph'
    schemaVersion = 1
    result = 'FAIL'
    offline = $true
    networkAccessed = $false
    readOnly = $true
    errorCode = 'INPUT_INVALID'
    safety = [ordered]@{ profileChanged = $false; workspaceChanged = $false; commandsExecuted = $false; pluginsExecuted = $false }
  } | ConvertTo-Json -Depth 12
  exit 1
}
