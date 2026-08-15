[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxFiles = 100
$script:MaxFileBytes = 1MB
$script:MaxTotalBytes = 8MB
$script:KnownContextMethods = @(
  'accept', 'collect', 'dispose', 'effect', 'emit', 'fork', 'get', 'inject',
  'logger', 'off', 'on', 'once', 'provide', 'scope', 'start', 'stop'
)
$script:TimerServices = @('clearImmediate', 'clearInterval', 'clearTimeout', 'setImmediate', 'setInterval', 'setTimeout')

function New-DshPreflightPrivacy {
  return [ordered]@{
    metadataOnly = $true
    sourceContentStored = $false
    sourceContentReported = $false
    rawArgumentsStored = $false
    credentialsStored = $false
    pathsStored = $false
  }
}

function New-DshPreflightReport {
  param(
    [Parameter(Mandatory = $true)][string]$Result,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$IssueCodes,
    [AllowEmptyCollection()][object[]]$Findings = @(),
    [AllowEmptyCollection()][object[]]$Ambiguities = @(),
    [AllowEmptyCollection()][object[]]$DeclaredInject = @(),
    [AllowEmptyCollection()][object[]]$ObservedServices = @(),
    [AllowEmptyCollection()][object[]]$MissingServices = @(),
    [int]$FileCount = 0,
    [int64]$TotalBytes = 0,
    [string]$InputKind = 'unknown',
    [bool]$WritesReport = $false
  )
  return [ordered]@{
    kind = 'dsh-plugin-preflight'
    schemaVersion = 1
    result = $Result
    comparisonStatus = $Result
    input = [ordered]@{
      kind = $InputKind
      fileCount = $FileCount
      totalBytes = $TotalBytes
    }
    summary = [ordered]@{
      declaredInjectCount = @($DeclaredInject).Count
      observedServiceCount = @($ObservedServices).Count
      missingServiceCount = @($MissingServices).Count
      findingCount = @($Findings).Count
      ambiguityCount = @($Ambiguities).Count
    }
    declaredInject = @($DeclaredInject)
    observedServices = @($ObservedServices)
    missingServices = @($MissingServices)
    findings = @($Findings)
    ambiguities = @($Ambiguities)
    issueCodes = @($IssueCodes)
    offline = $true
    networkAccessed = $false
    readOnly = $true
    executesPluginCode = $false
    autoDisabled = $false
    writesReport = $WritesReport
    privacy = New-DshPreflightPrivacy
  }
}

function Write-DshPreflightReport {
  param([Parameter(Mandatory = $true)]$Report, [string]$Path = '')
  $json = $Report | ConvertTo-Json -Depth 30
  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
  }
  return $json
}

function Get-DshPreflightRelativeName {
  param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
  try {
    $relative = [IO.Path]::GetRelativePath($Root, $Path)
    if ($relative -eq '..' -or $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar)) {
      return [IO.Path]::GetFileName($Path)
    }
    return $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
  } catch {
    return [IO.Path]::GetFileName($Path)
  }
}

function ConvertTo-DshPreflightCode {
  param([Parameter(Mandatory = $true)][string]$Text)
  $builder = [Text.StringBuilder]::new()
  $mode = 'normal'
  $escaped = $false
  for ($index = 0; $index -lt $Text.Length; $index++) {
    $current = [char]$Text[$index]
    $next = if ($index + 1 -lt $Text.Length) { [char]$Text[$index + 1] } else { [char]0 }
    if ($mode -eq 'line') {
      if ($current -eq "`r" -or $current -eq "`n") {
        [void]$builder.Append($current)
        $mode = 'normal'
      } else {
        [void]$builder.Append(' ')
      }
      continue
    }
    if ($mode -eq 'block') {
      if ($current -eq '*' -and $next -eq '/') {
        [void]$builder.Append('  ')
        $index++
        $mode = 'normal'
      } elseif ($current -eq "`r" -or $current -eq "`n") {
        [void]$builder.Append($current)
      } else {
        [void]$builder.Append(' ')
      }
      continue
    }
    if ($mode -in @('single', 'double', 'template')) {
      if ($escaped) {
        [void]$builder.Append(' ')
        $escaped = $false
      } elseif ($current -eq '\\') {
        [void]$builder.Append(' ')
        $escaped = $true
      } elseif (($mode -eq 'single' -and $current -eq "'") -or ($mode -eq 'double' -and $current -eq '"') -or ($mode -eq 'template' -and $current -eq '`')) {
        [void]$builder.Append(' ')
        $mode = 'normal'
      } elseif ($current -eq "`r" -or $current -eq "`n") {
        [void]$builder.Append($current)
      } else {
        [void]$builder.Append(' ')
      }
      continue
    }
    if ($current -eq '/' -and $next -eq '/') {
      [void]$builder.Append('  ')
      $index++
      $mode = 'line'
    } elseif ($current -eq '/' -and $next -eq '*') {
      [void]$builder.Append('  ')
      $index++
      $mode = 'block'
    } elseif ($current -eq "'") {
      [void]$builder.Append(' ')
      $mode = 'single'
      $escaped = $false
    } elseif ($current -eq '"') {
      [void]$builder.Append(' ')
      $mode = 'double'
      $escaped = $false
    } elseif ($current -eq '`') {
      [void]$builder.Append(' ')
      $mode = 'template'
      $escaped = $false
    } else {
      [void]$builder.Append($current)
    }
  }
  return $builder.ToString()
}

function Get-DshPreflightLineNumber {
  param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Index)
  if ($Index -le 0) { return 1 }
  return 1 + ([regex]::Matches($Text.Substring(0, [Math]::Min($Index, $Text.Length)), "`n")).Count
}

function Get-DshPreflightQuotedNames {
  param([Parameter(Mandatory = $true)][string]$Text)
  $names = [System.Collections.Generic.List[string]]::new()
  foreach ($match in [regex]::Matches($Text, '[''\"]([A-Za-z][A-Za-z0-9_.:-]{0,100})[''\"]')) {
    $name = [string]$match.Groups[1].Value
    if (-not $names.Contains($name)) { [void]$names.Add($name) }
  }
  return @($names)
}

function Get-DshPreflightFiles {
  param([Parameter(Mandatory = $true)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($item.PSIsContainer) {
    $root = $item.FullName
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop |
      Where-Object {
        $_.Extension -in @('.js', '.mjs', '.cjs') -and
        $_.FullName -notmatch '(?i)[\\/]node_modules[\\/]|[\\/]\.git[\\/]|[\\/]coverage[\\/]'
      } | Sort-Object FullName)
    return [PSCustomObject]@{ Root = $root; InputKind = 'directory'; Files = $files }
  }
  return [PSCustomObject]@{ Root = $item.Directory.FullName; InputKind = 'file'; Files = @($item) }
}

function Get-DshPreflightInvalidReport {
  param([string[]]$IssueCodes = @('INPUT_INVALID'))
  return New-DshPreflightReport -Result 'FAIL' -IssueCodes $IssueCodes -InputKind 'invalid'
}

try {
  if ([string]::IsNullOrWhiteSpace($InputPath) -or -not (Test-Path -LiteralPath $InputPath -PathType Any)) {
    $invalid = Get-DshPreflightInvalidReport
    Write-DshPreflightReport -Report $invalid -Path $OutputPath
    exit 1
  }
  $selection = Get-DshPreflightFiles -Path $InputPath
  $files = @($selection.Files)
  if ($files.Count -eq 0) {
    $invalid = Get-DshPreflightInvalidReport -IssueCodes @('NO_SOURCE_FILES')
    Write-DshPreflightReport -Report $invalid -Path $OutputPath
    exit 1
  }
  if ($files.Count -gt $script:MaxFiles) {
    $ambiguous = New-DshPreflightReport -Result 'MANUAL_REVIEW' -IssueCodes @('FILE_LIMIT') -Ambiguities @([ordered]@{ code = 'FILE_LIMIT'; limit = $script:MaxFiles }) -FileCount $files.Count -InputKind $selection.InputKind
    Write-DshPreflightReport -Report $ambiguous -Path $OutputPath
    exit 0
  }

  $declared = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $observed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $findings = [System.Collections.Generic.List[object]]::new()
  $ambiguities = [System.Collections.Generic.List[object]]::new()
  $totalBytes = [int64]0
  foreach ($file in $files) {
    if ($file.Length -gt $script:MaxFileBytes) {
      [void]$ambiguities.Add([ordered]@{ code = 'FILE_SIZE_LIMIT'; file = Get-DshPreflightRelativeName -Root $selection.Root -Path $file.FullName; limitBytes = $script:MaxFileBytes })
      continue
    }
    $totalBytes += [int64]$file.Length
    if ($totalBytes -gt $script:MaxTotalBytes) {
      [void]$ambiguities.Add([ordered]@{ code = 'TOTAL_SIZE_LIMIT'; limitBytes = $script:MaxTotalBytes })
      break
    }
    $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $code = ConvertTo-DshPreflightCode -Text $raw
    $relative = Get-DshPreflightRelativeName -Root $selection.Root -Path $file.FullName

    foreach ($match in [regex]::Matches($raw, '(?is)(?:^|[;\r\n])\s*(?:export\s+)?(?:const|let|var)\s+inject\s*=\s*\[(?<body>[^\]]*)\]')) {
      foreach ($name in @(Get-DshPreflightQuotedNames -Text ([string]$match.Groups['body'].Value))) { [void]$declared.Add($name) }
    }
    foreach ($match in [regex]::Matches($raw, '(?is)(?:^|[;\r\n])\s*(?:export\s+)?(?:const|let|var)\s+inject\s*=\s*(?<rhs>[^;\r\n]+)')) {
      if (-not ([string]$match.Groups['rhs'].Value).TrimStart().StartsWith('[')) {
        [void]$ambiguities.Add([ordered]@{ code = 'DYNAMIC_INJECT_DECLARATION'; file = $relative })
      }
    }
    foreach ($match in [regex]::Matches($raw, '(?is)ctx\s*\.\s*inject\s*\(\s*\[(?<body>[^\]]*)\]')) {
      foreach ($name in @(Get-DshPreflightQuotedNames -Text ([string]$match.Groups['body'].Value))) { [void]$declared.Add($name) }
    }
    if ($code -match '(?i)\bctx\s*\[') {
      [void]$ambiguities.Add([ordered]@{ code = 'DYNAMIC_CONTEXT_ACCESS'; file = $relative })
    }
    foreach ($match in [regex]::Matches($code, '(?<![A-Za-z0-9_$])ctx\s*\.\s*(?<name>[A-Za-z_$][A-Za-z0-9_$]*)')) {
      $name = [string]$match.Groups['name'].Value
      if ($script:KnownContextMethods -contains $name) { continue }
      $service = if ($script:TimerServices -contains $name) { 'timer' } else { $name }
      [void]$observed.Add($service)
      if (-not $declared.Contains($service)) {
        [void]$findings.Add([ordered]@{
          code = 'MISSING_INJECT'
          service = $service
          file = $relative
          line = Get-DshPreflightLineNumber -Text $code -Index $match.Index
          evidence = "ctx.$name"
        })
      }
    }
  }

  $declaredValues = @($declared | Sort-Object)
  $observedValues = @($observed | Sort-Object)
  $missingValues = @($findings | ForEach-Object { [string]$_.service } | Sort-Object -Unique)
  $issueCodes = [System.Collections.Generic.List[string]]::new()
  if ($findings.Count -gt 0) { [void]$issueCodes.Add('MISSING_INJECT') }
  foreach ($ambiguity in @($ambiguities)) { if (-not $issueCodes.Contains([string]$ambiguity.code)) { [void]$issueCodes.Add([string]$ambiguity.code) } }
  $result = if ($findings.Count -gt 0) { 'FAIL' } elseif ($ambiguities.Count -gt 0) { 'MANUAL_REVIEW' } else { 'PASS' }
  if ($result -eq 'PASS' -and $issueCodes.Count -eq 0) { [void]$issueCodes.Add('NONE') }
  $report = New-DshPreflightReport -Result $result -IssueCodes @($issueCodes) -Findings @($findings) -Ambiguities @($ambiguities) -DeclaredInject $declaredValues -ObservedServices $observedValues -MissingServices $missingValues -FileCount $files.Count -TotalBytes $totalBytes -InputKind $selection.InputKind -WritesReport (-not [string]::IsNullOrWhiteSpace($OutputPath))
  Write-DshPreflightReport -Report $report -Path $OutputPath
  if ($result -eq 'FAIL') { exit 1 }
  exit 0
} catch {
  $invalid = Get-DshPreflightInvalidReport -IssueCodes @('INPUT_INVALID')
  Write-DshPreflightReport -Report $invalid -Path $OutputPath
  exit 1
}
