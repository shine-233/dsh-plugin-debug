[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string[]]$InputPath,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [switch]$Zip,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReproMaxInputBytes = 2MB
$script:ReproMaxSources = 32
$script:ReproMaxArrayItems = 200
$script:ReproMaxDepth = 8
$script:ReproAllowedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($key in @(
    'schemaVersion','kind','result','status','confidence','evidence','source','layer','id','incidentId',
    'observationId','pageObservationId','pluginId','plugin','module','moduleId','slot','slotId','callId',
    'seq','sequence','turn','step','tool','toolName','name','eventType','type','state','phase','errorCode',
    'errorType','error','errorCount','warningCount','failedCount','failureCount','pendingCount','totalCount',
    'count','omittedCount','truncated','firstObserved','lastObserved','statusCode','ready','available',
    'apiObserved','model','provider','route','sandbox','approval','permission','permissions','profile',
    'profileName','workspaceProvided','sessionProvided','pointerEvidenceProvided','componentStatusCounts',
    'componentHashes','components','pluginInventory','runtime','profileManifest','webReadiness','quarantine',
    'restart','knownGood','sessionHealth','toolCallObservation','totals','observations','events','calls',
    'plugins','findings','checks','privacy','collection','rawPayloadStored','toolResultBodiesStored',
    'rawSessionContentStored','envContentsStored','credentialsStored','networkPayloadSent','modelPromptSent',
    'toolExecuted','readOnlyCollection','writesLocalReport','sourceSearchIncomplete','causalAttribution',
    'duplicateCount','conflictCount','addressed','receipt','operation','mutates','requiresApproval','expiresAt',
    'evidenceHash','preImageHash','postImageHash','action','records','generatedAt','createdAt','observedAt',
    'sha256','bytes','artifactCount','sourceCount','sourceKinds','zipCreated'
  )) { [void]$script:ReproAllowedKeys.Add($key) }

$script:ReproDynamicContainers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($key in @('components','componentHashes','plugins','findings','checks','observations','events','calls','records')) {
  [void]$script:ReproDynamicContainers.Add($key)
}

function Get-ReproProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-ReproObject {
  param([AllowNull()]$Value)
  return $null -ne $Value -and
    $Value -isnot [string] -and
    $Value -isnot [System.ValueType] -and
    $null -ne $Value.PSObject.Properties
}

function Test-ReproDeniedKey {
  param([Parameter(Mandatory = $true)][string]$Name)
  return $Name -match '(?i)(argument|body|content|text|detail|path|cwd|root|home|url|uri|cookie|token|secret|password|header|command|script|shell|expression|eval|stdout|stderr|stack|response|request|prompt|query|payload|session.?id|input)'
}

function Test-ReproSafeIdentifier {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $text = $Value.Trim()
  if ($text.Length -gt 160 -or $text -match '[\r\n\t]') { return $false }
  if ($text -match '(?i)([A-Z]:[\\/]|\\\\|https?://|file:|authorization\s*[:=]|bearer\s+|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|Remove-Item|Invoke-|cmd\.exe|powershell(?:\.exe)?|bash\s+-c)') { return $false }
  return $true
}

function Convert-ReproScalar {
  param([AllowNull()]$Value, [string]$Key = '')
  if ($null -eq $Value) { return $null }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
      $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [decimal] -or
      $Value -is [double] -or $Value -is [single]) {
    return $Value
  }
  $text = ([string]$Value).Trim()
  if (-not (Test-ReproSafeIdentifier -Value $text)) { return $null }
  if ($Key -match '(?i)^result$' -and $text.ToUpperInvariant() -notin @('PASS','PARTIAL','FAIL','WARN','COMPLETE','UNAVAILABLE','INCONCLUSIVE','NOT_REQUESTED')) { return $null }
  if ($Key -match '(?i)^(sandbox|approval|permission)$' -and $text.ToLowerInvariant() -notin @('danger-full-access','workspace-write','read-only','readonly','ask','allow','deny','manual','none','unknown','not-observed','required')) { return $null }
  if ($Key -match '(?i)(sha256|imagehash|evidencehash|preimagehash|postimagehash)' -and $text -notmatch '^[a-f0-9]{16,128}$') { return $null }
  if ($Key -match '(?i)(generatedat|createdat|observedat|expiresat)' -and $text -notmatch '^\d{4}-\d{2}-\d{2}T') { return $null }
  return $text
}

function Convert-ReproValue {
  param(
    [AllowNull()]$Value,
    [string]$Key = '',
    [int]$Depth = 0,
    [bool]$AllowDynamic = $false
  )
  if ($null -eq $Value -or $Depth -gt $script:ReproMaxDepth) { return $null }
  if (-not (Test-ReproObject -Value $Value) -and
      ($Value -isnot [System.Collections.IEnumerable] -or $Value -is [string])) {
    return Convert-ReproScalar -Value $Value -Key $Key
  }
  if ($Value -is [string] -or $Value -is [System.ValueType]) { return Convert-ReproScalar -Value $Value -Key $Key }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
    $items = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($item in $Value) {
      if ($index -ge $script:ReproMaxArrayItems) { break }
      $projected = Convert-ReproValue -Value $item -Key $Key -Depth ($Depth + 1) -AllowDynamic:$false
      if ($null -ne $projected) { [void]$items.Add($projected) }
      $index++
    }
    return @($items)
  }
  $record = [ordered]@{}
  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    $name = [string]$property.Name
    if (Test-ReproDeniedKey -Name $name) { continue }
    $allowed = $script:ReproAllowedKeys.Contains($name) -or
      ($AllowDynamic -and (Test-ReproSafeIdentifier -Value $name))
    if (-not $allowed) { continue }
    $childDynamic = $script:ReproDynamicContainers.Contains($name)
    $projected = Convert-ReproValue -Value $property.Value -Key $name -Depth ($Depth + 1) -AllowDynamic:$childDynamic
    if ($null -ne $projected) { $record[$name] = $projected }
  }
  if ($record.Count -eq 0) { return $null }
  return $record
}

function Resolve-ReproInputPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { throw 'input file is unavailable' }
  if (-not $item.PSIsContainer -eq $false -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'input must be a regular JSON file' }
  if ([IO.Path]::GetExtension($item.FullName).ToLowerInvariant() -ne '.json') { throw 'input must use the JSON format' }
  if ([int64]$item.Length -gt $script:ReproMaxInputBytes) { throw 'input is larger than the bounded repro limit' }
  return [IO.Path]::GetFullPath($item.FullName)
}

function Resolve-ReproOutputPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'output path is required' }
  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($full)
  if ([string]::IsNullOrWhiteSpace($root) -or $full.TrimEnd('\','/') -eq $root.TrimEnd('\','/')) { throw 'output path cannot be a filesystem root' }
  if (Test-Path -LiteralPath $full) {
    $item = Get-Item -LiteralPath $full -Force
    if (-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'output path must be a regular directory' }
  }
  return $full
}

function Test-ReproWithin {
  param([Parameter(Mandatory = $true)][string]$Child, [Parameter(Mandatory = $true)][string]$Parent)
  $childFull = [IO.Path]::GetFullPath($Child).TrimEnd('\','/')
  $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
  return $childFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase) -or
    $childFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $childFull.StartsWith($parentFull + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReproHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-ReproSourceKind {
  param([Parameter(Mandatory = $true)]$Value)
  $kind = [string](Get-ReproProperty -Object $Value -Name 'kind')
  if ($kind -match '(?i)incident') { return 'incident' }
  if ($kind -match '(?i)trace|tool.?call') { return 'trace' }
  if ($kind -match '(?i)pointer|provenance') { return 'pointer' }
  if ($kind -match '(?i)health|diagnostic') { return 'diagnostics' }
  if ($kind -match '(?i)receipt|repair') { return 'receipt' }
  return 'unknown'
}

function Get-ReproGeneratedAt {
  param([object[]]$Values = @())
  foreach ($value in @($Values)) {
    $candidate = Convert-ReproScalar -Value (Get-ReproProperty -Object $value -Name 'generatedAt') -Key 'generatedAt'
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { return [string]$candidate }
    $candidate = Convert-ReproScalar -Value (Get-ReproProperty -Object $value -Name 'createdAt') -Key 'createdAt'
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { return [string]$candidate }
  }
  return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-ReproSourceIncidentId {
  param([object[]]$Values = @())
  foreach ($value in @($Values)) {
    foreach ($key in @('incidentId','id')) {
      $candidate = Convert-ReproScalar -Value (Get-ReproProperty -Object $value -Name $key) -Key $key
      if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { return [string]$candidate }
    }
  }
  return $null
}

try {
  $normalizedInputPaths = [System.Collections.Generic.List[string]]::new()
  foreach ($rawInputPath in @($InputPath)) {
    if ([string]::IsNullOrWhiteSpace([string]$rawInputPath)) { continue }
    foreach ($candidateInputPath in ([string]$rawInputPath -split '\|')) {
      if (-not [string]::IsNullOrWhiteSpace($candidateInputPath)) { [void]$normalizedInputPaths.Add($candidateInputPath) }
    }
  }
  $InputPath = @($normalizedInputPaths)
  if ($InputPath.Count -eq 0 -or $InputPath.Count -gt $script:ReproMaxSources) { throw 'input count is outside the bounded repro limit' }
  $inputFiles = [System.Collections.Generic.List[string]]::new()
  foreach ($path in $InputPath) {
    $resolvedInput = Resolve-ReproInputPath -Path $path
    $duplicate = $false
    foreach ($existingInput in $inputFiles) {
      if ($existingInput.Equals($resolvedInput, [StringComparison]::OrdinalIgnoreCase)) { $duplicate = $true; break }
    }
    if (-not $duplicate) { [void]$inputFiles.Add($resolvedInput) }
  }
  $resolvedOutput = Resolve-ReproOutputPath -Path $OutputPath
  foreach ($inputFile in $inputFiles) {
    if (Test-ReproWithin -Child $inputFile -Parent $resolvedOutput) { throw 'output path overlaps an input file' }
  }

  $values = [System.Collections.Generic.List[object]]::new()
  $sources = [System.Collections.Generic.List[object]]::new()
  foreach ($inputFile in $inputFiles) {
    try { $value = Get-Content -LiteralPath $inputFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw 'input JSON is malformed' }
    if ($null -eq $value) { throw 'input JSON is empty' }
    [void]$values.Add($value)
    $projected = Convert-ReproValue -Value $value
    if ($null -eq $projected) { $projected = [ordered]@{} }
    [void]$sources.Add([ordered]@{
      sourceIndex = $sources.Count
      sourceKind = Get-ReproSourceKind -Value $value
      evidence = $projected
    })
  }

  $sourceKinds = @($sources | ForEach-Object { [string]$_.sourceKind } | Sort-Object -Unique)
  $generatedAt = Get-ReproGeneratedAt -Values @($values)
  $sourceIncidentId = Get-ReproSourceIncidentId -Values @($values)
  if (-not (Test-Path -LiteralPath $resolvedOutput)) { [IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null }
  foreach ($name in @('repro.json','manifest.json','README.txt')) {
    $artifactPath = Join-Path $resolvedOutput $name
    if ((Test-Path -LiteralPath $artifactPath -PathType Leaf) -and -not $Force) { throw 'output already contains a generated artifact; pass Force to replace it' }
  }
  $zipPath = $resolvedOutput + '.zip'
  if ($Zip -and (Test-Path -LiteralPath $zipPath -PathType Leaf) -and -not $Force) { throw 'zip output already exists; pass Force to replace it' }

  $reproPath = Join-Path $resolvedOutput 'repro.json'
  $manifestPath = Join-Path $resolvedOutput 'manifest.json'
  $readmePath = Join-Path $resolvedOutput 'README.txt'
  $repro = [ordered]@{
    schemaVersion = 1
    kind = 'dsh-debug-repro'
    generatedAt = $generatedAt
    sourceIncidentId = $sourceIncidentId
    sourceCount = $sources.Count
    sourceKinds = @($sourceKinds)
    sources = @($sources)
    rawPayloadStored = $false
    privacy = [ordered]@{
      toolArgumentsStored = $false
      toolResultBodiesStored = $false
      sessionContentStored = $false
      workspaceContentStored = $false
      envContentsStored = $false
      credentialsStored = $false
      absolutePathsStored = $false
      networkAccessed = $false
    }
  }
  [IO.File]::WriteAllText($reproPath, ($repro | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
  $readme = @(
    'DSH Debug minimal reproduction package',
    '',
    'This package contains bounded, metadata-only evidence for offline issue triage.',
    'It does not contain tool arguments, tool result bodies, session text, workspace text, credentials, cookies, tokens, or absolute paths.',
    'The source inputs were read as JSON and were not modified.',
    'The package was produced without network access and without executing a tool or model prompt.',
    '',
    'Artifact contract: repro.json, manifest.json, README.txt.'
  ) -join "`r`n"
  [IO.File]::WriteAllText($readmePath, $readme + "`r`n", [Text.UTF8Encoding]::new($false))
  $manifest = [ordered]@{
    schemaVersion = 1
    kind = 'dsh-debug-repro-manifest'
    generatedAt = $generatedAt
    sourceIncidentId = $sourceIncidentId
    sourceCount = $sources.Count
    artifactAllowlist = @('repro.json','manifest.json','README.txt')
    artifacts = @(
      [ordered]@{ name = 'repro.json'; bytes = (Get-Item -LiteralPath $reproPath).Length; sha256 = Get-ReproHash -Path $reproPath },
      [ordered]@{ name = 'manifest.json'; bytes = $null; sha256 = 'self-excluded-from-hash' },
      [ordered]@{ name = 'README.txt'; bytes = (Get-Item -LiteralPath $readmePath).Length; sha256 = Get-ReproHash -Path $readmePath }
    )
    rawPayloadStored = $false
    networkAccessed = $false
    redactionPolicy = [ordered]@{
      allowedEvidence = @('plugin/module/slot ids','Tool Call names and ids','sequence and status metadata','permission enums','error code/type summaries','component hashes')
      excludedFields = @('arguments','results','session text','workspace text','.env','cookies','tokens','authorization','absolute paths','commands','scripts','urls')
      rawPayloadStored = $false
    }
  }
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
  if ($Zip) {
    Compress-Archive -LiteralPath @($reproPath,$manifestPath,$readmePath) -DestinationPath $zipPath -Force
  }
  [ordered]@{
    result = 'PASS'
    kind = 'dsh-debug-repro-export'
    schemaVersion = 1
    artifactCount = 3
    sourceCount = $sources.Count
    sourceKinds = @($sourceKinds)
    outputDirectoryName = [IO.Path]::GetFileName($resolvedOutput.TrimEnd('\','/'))
    zipCreated = [bool]$Zip
    zipName = if ($Zip) { [IO.Path]::GetFileName($zipPath) } else { $null }
    rawPayloadStored = $false
    networkAccessed = $false
    inputChanged = $false
  } | ConvertTo-Json -Depth 20
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-debug-repro-export'
    schemaVersion = 1
    errorCode = if ($_.Exception.Message -match '(?i)JSON|malformed|empty') { 'INPUT_INVALID' } elseif ($_.Exception.Message -match '(?i)overlap|root|output') { 'OUTPUT_REJECTED' } else { 'EXPORT_FAILED' }
    rawPayloadStored = $false
    networkAccessed = $false
    inputChanged = $false
  } | ConvertTo-Json -Depth 12
  exit 1
}
